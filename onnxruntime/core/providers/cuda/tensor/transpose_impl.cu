// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "core/providers/cuda/cu_inc/common.cuh"
#include "transpose_impl.h"

namespace onnxruntime {
namespace cuda {

constexpr int TILE_DIM = 32;
constexpr int BLOCK_ROWS = 8;

template <typename T>
__global__ void _Transpose3DKernel(const TArray<int64_t> input_shape,
                                   const TArray<int64_t> input_strides,
                                   const T* input_data, T* output_data) {
  __shared__ float tile[TILE_DIM][TILE_DIM+1];

  int x = blockIdx.x * TILE_DIM + threadIdx.x;
  int y = blockIdx.y * TILE_DIM + threadIdx.y;
  int width = input_shape[2];

  for (int j = 0; j < TILE_DIM; j += BLOCK_ROWS)
    tile[threadIdx.y+j][threadIdx.x] = input_data[blockIdx.z * input_strides[0] + (y+j)*width + x];

  __syncthreads();

  x = blockIdx.y * TILE_DIM + threadIdx.x;
  y = blockIdx.x * TILE_DIM + threadIdx.y;

  for (int j = 0; j < TILE_DIM; j += BLOCK_ROWS)
    output_data[blockIdx.z * input_strides[0] + (y+j)*width + x] = tile[threadIdx.x][threadIdx.y + j];
}

bool canDoTranspose3D(int32_t rank,
                      const std::vector<int64_t>& input_dims,
                      const std::vector<size_t>& permutations) {
  if (rank == 3 &&
      input_dims[1] % TILE_DIM == 0 && input_dims[2] % TILE_DIM == 0 &&
      permutations[1] == 2 && permutations[2] == 1) {
    return true;
  }
  return false;
}

Status Transpose3DImpl(size_t element_size,
                       const TArray<int64_t>& input_shape, const TArray<int64_t>& input_strides,
                       const void* input_data, void* output_data, int64_t N) {
  dim3 block_size(TILE_DIM, BLOCK_ROWS);
  dim3 grid_size(input_shape[2]/TILE_DIM, input_shape[1]/TILE_DIM, input_shape[0]);

  switch (element_size) {
    case sizeof(int8_t):
      _Transpose3DKernel<int8_t><<<grid_size, block_size, 0>>>(
          input_shape, input_strides,
          reinterpret_cast<const ToCudaType<int8_t>::MappedType*>(input_data),
          reinterpret_cast<ToCudaType<int8_t>::MappedType*>(output_data));
      break;
    case sizeof(int16_t):
      _Transpose3DKernel<int16_t><<<grid_size, block_size, 0>>>(
          input_shape, input_strides,
          reinterpret_cast<const int16_t*>(input_data),
          reinterpret_cast<int16_t*>(output_data));
      break;
    case sizeof(int32_t):
      _Transpose3DKernel<int32_t><<<grid_size, block_size, 0>>>(
          input_shape, input_strides,
          reinterpret_cast<const ToCudaType<int32_t>::MappedType*>(input_data),
          reinterpret_cast<ToCudaType<int32_t>::MappedType*>(output_data));
      break;
    case sizeof(int64_t):
      _Transpose3DKernel<int64_t><<<grid_size, block_size, 0>>>(
          input_shape, input_strides,
          reinterpret_cast<const ToCudaType<int64_t>::MappedType*>(input_data),
          reinterpret_cast<ToCudaType<int64_t>::MappedType*>(output_data));
      break;
    default:
      return ORT_MAKE_STATUS(ONNXRUNTIME, FAIL, "Type not supported for transpose on CUDA. Element size was ",
                              element_size);
  }

  return Status::OK();
}

template <typename T, int element_size>
__global__ void _Transpose4DKernel(const TArray<int64_t> input_strides, const T* input_data,
                                   const TArray<int64_t> output_strides, T* output_data, CUDA_LONG N) {
  // output coordinates will be: blockIdx.y, blockIdx.x, threadIdx.y, threadIdx.x
  CUDA_LONG input_index = (blockIdx.y * input_strides[0] +
                           blockIdx.x * input_strides[1] +
                           threadIdx.y * input_strides[2]) / (4 * 4 / element_size) +
                           threadIdx.x * input_strides[3];

  CUDA_LONG output_index = (blockIdx.y * output_strides[0] +
                            blockIdx.x * output_strides[1] +
                            threadIdx.y * output_strides[2]) / (4 * 4 / element_size) +
                            threadIdx.x * output_strides[3];

  const int4* v_input = reinterpret_cast<const int4*>(input_data);
  int4* v_output = reinterpret_cast<int4*>(output_data);

  if (input_index < N && output_index < N) {
    v_output[output_index] = v_input[input_index];
  }
}

bool canDoTranspose4D(const cudaDeviceProp& prop,
                      size_t element_size,
                      int32_t rank,
                      const std::vector<int64_t>& input_dims,
                      const std::vector<size_t>& permutations) {
  // In Tranpose4D, vector of int4 will be used.
  int64_t num_threads_per_block = input_dims[2] * input_dims[3] / (4 * sizeof(int) / element_size);
  if (rank == 4 && permutations[3] == 3 &&
      num_threads_per_block <= prop.maxThreadsPerBlock &&
      // num_threads_per_block must be aligned with warp size: 32
      ((num_threads_per_block & (prop.warpSize - 1)) == 0)) {
    return true;
  }
  return false;
}

Status Transpose4DImpl(size_t element_size, const TArray<int64_t>& input_shape, const TArray<int64_t>& input_strides, const void* input_data,
                       const TArray<int64_t>& output_strides, void* output_data, int64_t N) {
  dim3 block_size(input_shape[3], input_shape[2]);
  dim3 grid_size(input_shape[1], input_shape[0]);

  switch (element_size) {
    case sizeof(int8_t):
      block_size.x = block_size.x / (4 * 4 / sizeof(int8_t));
      N /= (4 * 4 / sizeof(int8_t));
      _Transpose4DKernel<int8_t, sizeof(int8_t)><<<grid_size, block_size, 0>>>(
          input_strides, reinterpret_cast<const ToCudaType<int8_t>::MappedType*>(input_data),
          output_strides, reinterpret_cast<ToCudaType<int8_t>::MappedType*>(output_data), N);
      break;
    case sizeof(int16_t):
      block_size.x = block_size.x / (4 * 4 / sizeof(int16_t));
      N /= (4 * 4 / sizeof(int16_t));
      _Transpose4DKernel<int16_t, sizeof(int16_t)><<<grid_size, block_size, 0>>>(
          input_strides, reinterpret_cast<const int16_t*>(input_data),
          output_strides, reinterpret_cast<int16_t*>(output_data), N);
      break;
    case sizeof(int32_t):
      block_size.x = block_size.x / (4 * 4 / sizeof(int32_t));
      N /= (4 * 4 / sizeof(int32_t));
      _Transpose4DKernel<int32_t, sizeof(int32_t)><<<grid_size, block_size, 0>>>(
          input_strides, reinterpret_cast<const ToCudaType<int32_t>::MappedType*>(input_data),
          output_strides, reinterpret_cast<ToCudaType<int32_t>::MappedType*>(output_data), N);
      break;
    case sizeof(int64_t):
      block_size.x = block_size.x / (4 * 4 / sizeof(int64_t));
      N /= (4 * 4 / sizeof(int64_t));
      _Transpose4DKernel<int64_t, sizeof(int64_t)><<<grid_size, block_size, 0>>>(
          input_strides, reinterpret_cast<const ToCudaType<int64_t>::MappedType*>(input_data),
          output_strides, reinterpret_cast<ToCudaType<int64_t>::MappedType*>(output_data), N);
      break;
    default:
      return ORT_MAKE_STATUS(ONNXRUNTIME, FAIL, "Type not supported for transpose on CUDA. Element size was ",
                              element_size);
  }

  return Status::OK();
}

template <typename T>
__global__ void _TransposeKernel(int32_t shape_rank, const TArray<int64_t> input_strides,
                                 const T* input_data, const TArray<fast_divmod> output_strides, T* output_data, CUDA_LONG N) {
  CALCULATE_ELEMENTWISE_INDEX_OR_EXIT(id, N);
  CUDA_LONG input_index = 0;
  CUDA_LONG output_index = id;

  #pragma unroll
  for (auto dim = 0; dim < input_strides.GetCapacity(); ++dim) {
    if (dim >= shape_rank) {
      break;
    }
    int out_coord, r;
    output_strides[dim].divmod(output_index, out_coord, r);
    output_index = r;
    input_index += input_strides[dim] * out_coord;
  }
  output_data[id] = input_data[input_index];
}

Status TransposeImpl(size_t element_size, int32_t shape_rank, const TArray<int64_t>& input_strides,
                     const void* input_data, const TArray<fast_divmod>& fdm_output_strides, void* output_data, int64_t N) {
  int blocksPerGrid = (int)(ceil(static_cast<float>(N) / GridDim::maxThreadsPerBlock));
  switch (element_size) {
    case sizeof(int8_t):
      _TransposeKernel<int8_t><<<blocksPerGrid, GridDim::maxThreadsPerBlock, 0>>>(
          shape_rank, input_strides,
          reinterpret_cast<const ToCudaType<int8_t>::MappedType*>(input_data),
          fdm_output_strides,
          reinterpret_cast<ToCudaType<int8_t>::MappedType*>(output_data),
          N);
      break;
    case sizeof(int16_t):
      _TransposeKernel<int16_t><<<blocksPerGrid, GridDim::maxThreadsPerBlock, 0>>>(
          shape_rank, input_strides,
          reinterpret_cast<const ToCudaType<int16_t>::MappedType*>(input_data),
          fdm_output_strides,
          reinterpret_cast<ToCudaType<int16_t>::MappedType*>(output_data),
          N);
      break;
    case sizeof(int32_t):
      _TransposeKernel<int32_t><<<blocksPerGrid, GridDim::maxThreadsPerBlock, 0>>>(
          shape_rank, input_strides,
          reinterpret_cast<const ToCudaType<int32_t>::MappedType*>(input_data),
          fdm_output_strides,
          reinterpret_cast<ToCudaType<int32_t>::MappedType*>(output_data),
          N);
      break;
    case sizeof(int64_t):
      _TransposeKernel<int64_t><<<blocksPerGrid, GridDim::maxThreadsPerBlock, 0>>>(
          shape_rank, input_strides,
          reinterpret_cast<const ToCudaType<int64_t>::MappedType*>(input_data),
          fdm_output_strides,
          reinterpret_cast<ToCudaType<int64_t>::MappedType*>(output_data),
          N);
      break;
    default:
      return ORT_MAKE_STATUS(ONNXRUNTIME, FAIL, "Type not supported for transpose on CUDA. Element size was ",
                             element_size);
  }

  return Status::OK();
}

}  // namespace cuda
}  // namespace onnxruntime
