/* Copyright (c) 2024 PaddlePaddle Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#include "paddle/phi/kernels/funcs/fake_quantize_functor.h"

namespace phi {
namespace funcs {

template <typename T>
struct QuantizeDataType {
  using type = T;
};

template <>
struct QuantizeDataType<phi::dtype::float16> {
  using type = float;
};

template <typename T>
__global__ void FindAbsMaxKernel(const T *in, const int n, T *out) {
  int bid = threadIdx.x + blockIdx.x * blockDim.x;
  int tid = threadIdx.x;

  extern __shared__ char *shared_max_data_tmp[];
  auto shared_max_data = reinterpret_cast<T *>(shared_max_data_tmp);
  if (gridDim.x > 1) {
    T local_max_data = T(0);
    for (int i = bid; i < n; i += blockDim.x * gridDim.x) {
      T tmp = abs(in[i]);
      if (tmp > local_max_data) {
        local_max_data = tmp;
      }
    }
    shared_max_data[tid] = local_max_data;
  } else {
    if (bid < n) {
      shared_max_data[tid] = abs(in[bid]);
    } else {
      shared_max_data[tid] = T(0);
    }
  }
  __syncthreads();

  for (int i = blockDim.x / 2; i > 0; i >>= 1) {
    if (tid < i && (shared_max_data[tid] < shared_max_data[tid + i])) {
      shared_max_data[tid] = shared_max_data[tid + i];
    }
    __syncthreads();
  }
  if (tid == 0) {
    out[blockIdx.x] = shared_max_data[0];
  }
}

template <typename T>
__global__ void ClipAndQuantKernel(const T *in,
                                   const T *scale,
                                   const int bin_cnt,
                                   const int round_type,
                                   const int n,
                                   T *out) {
  int bid = threadIdx.x + blockIdx.x * blockDim.x;
  int tid = threadIdx.x;

  using ComputeDataType = typename QuantizeDataType<T>::type;

  ComputeDataType s = static_cast<ComputeDataType>(scale[0]);
  ComputeDataType inv_s = inverse(s);
  ComputeDataType bin_cnt_t = static_cast<ComputeDataType>(bin_cnt);

  for (int i = bid; i < n; i += blockDim.x * gridDim.x) {
    ComputeDataType x = static_cast<ComputeDataType>(in[i]);
    if (round_type == 0) {
      x = bin_cnt_t * inv_s * x;
      x = roundWithTiesToEven(x);
      ComputeDataType max_bound = bin_cnt_t;
      ComputeDataType min_bound = -bin_cnt_t - static_cast<ComputeDataType>(1);
      x = x > max_bound ? max_bound : x;
      x = x < min_bound ? min_bound : x;
      out[i] = static_cast<T>(x);
    } else {
      ComputeDataType v = x > s ? s : x;
      v = v < -s ? -s : v;
      v = bin_cnt_t * inv_s * v;
      out[i] = static_cast<T>(round(v));
    }
  }
}

template <typename T>
__global__ void FindMovingAverageAbsMaxKernel(const T *in_state,
                                              const T *in_accum,
                                              const T *cur_scale,
                                              const T rate,
                                              T *out_state,
                                              T *out_accum,
                                              T *out_scale) {
  T state = rate * (*in_state) + T(1.0f);
  T accum = rate * (*in_accum) + (*cur_scale);
  *out_state = state;
  *out_accum = accum;
  *out_scale = accum / state;
}

template <typename T>
__global__ void FindRangeAbsMaxAndFillArray(const T *cur_scale,
                                            const T *last_scale,
                                            const int64_t *iter,
                                            const int window_size,
                                            T *scale_arr,
                                            T *out_scale,
                                            int *need_find_max,
                                            int *out_size) {
  int it = iter[0];
  int idx = it % window_size;
  T removed = scale_arr[idx];
  T cur = cur_scale[0];
  scale_arr[idx] = cur;
  T max = last_scale[0];
  out_scale[0] = max < cur ? cur : max;
  if (fabs(static_cast<typename QuantizeDataType<T>::type>(removed - max)) <
      1e-6) {
    need_find_max[0] = 1;
    out_size[0] = it > window_size ? window_size : it;
  } else {
    need_find_max[0] = 0;
  }
}

template <typename Context, typename T>
void FindAbsMaxFunctor<Context, T>::operator()(const Context &ctx,
                                               const T *in,
                                               const int num,
                                               T *out) {
  int block = 1024;
  int grid = (block - 1 + num) / block;
  grid = (grid > block) ? block : grid;

  DenseTensor max;
  max.Resize(common::make_ddim({grid}));
  T *max_data = ctx.template Alloc<T>(&max);
  FindAbsMaxKernel<T>
      <<<grid, block, 1024 * sizeof(T), ctx.stream()>>>(in, num, max_data);
  FindAbsMaxKernel<T>
      <<<1, block, 1024 * sizeof(T), ctx.stream()>>>(max_data, grid, out);
}

template <typename Context, typename T>
void ClipAndFakeQuantFunctor<Context, T>::operator()(const Context &ctx,
                                                     const DenseTensor &in,
                                                     const DenseTensor &scale,
                                                     const int bin_cnt,
                                                     const int round_type,
                                                     DenseTensor *out) {
  int num = in.numel();
  int block = 1024;
  int grid = (block - 1 + num) / block;

  const T *in_data = in.data<T>();
  const T *scale_data = scale.data<T>();
  T *out_data = ctx.template Alloc<T>(out);

  ClipAndQuantKernel<T><<<grid, block, 0, ctx.stream()>>>(
      in_data, scale_data, bin_cnt, round_type, num, out_data);
}

template <typename Context, typename T>
void FindMovingAverageAbsMaxFunctor<Context, T>::operator()(
    const Context &ctx,
    const DenseTensor &in_accum,
    const DenseTensor &in_state,
    const T *cur_scale,
    const float rate,
    DenseTensor *out_state,
    DenseTensor *out_accum,
    DenseTensor *out_scale) {
  T rate_t = static_cast<T>(rate);
  T *out_state_data = ctx.template Alloc<T>(out_state);
  T *out_accum_data = ctx.template Alloc<T>(out_accum);
  T *out_scale_data = ctx.template Alloc<T>(out_scale);

  FindMovingAverageAbsMaxKernel<T>
      <<<1, 1, 0, ctx.stream()>>>(in_state.data<T>(),
                                  in_accum.data<T>(),
                                  cur_scale,
                                  rate_t,
                                  out_state_data,
                                  out_accum_data,
                                  out_scale_data);
}

template <typename T>
__global__ void FindChannelAbsMaxKernelQuantAxis0(const T *in,
                                                  const int n,
                                                  const int c,
                                                  T *out) {
  int tid = threadIdx.x;
  int channel_size = n / c;
  const T *in_c = in + blockIdx.x * channel_size;
  extern __shared__ char *shared_max_data_tmp[];
  auto shared_max_data = reinterpret_cast<T *>(shared_max_data_tmp);
  T local_max_data = T(0);
  for (int i = tid; i < channel_size; i += blockDim.x) {
    T tmp = static_cast<T>(
        fabs(static_cast<typename QuantizeDataType<T>::type>(in_c[i])));
    if (tmp > local_max_data) {
      local_max_data = tmp;
    }
  }
  shared_max_data[tid] = local_max_data;
  __syncthreads();
  for (int i = blockDim.x / 2; i > 0; i >>= 1) {
    if (tid < i && (shared_max_data[tid] < shared_max_data[tid + i])) {
      shared_max_data[tid] = shared_max_data[tid + i];
    }
    __syncthreads();
  }
  if (tid == 0) {
    out[blockIdx.x] = shared_max_data[0];
  }
}

template <typename T>
__global__ void FindChannelAbsMaxKernelQuantAxis1(
    const T *in, const int n, const int cin, const int cout, T *out) {
  extern __shared__ char *shared_max_data_tmp[];
  auto shared_max_data = reinterpret_cast<T *>(shared_max_data_tmp);
  int cout_wh_size = n / cin;
  int wh_size = n / (cin * cout);

  int tid = threadIdx.x;
  int bid = blockIdx.x;
  const T *in_current = in + tid * cout_wh_size + bid * wh_size;
  T local_max_data = T(0);
  for (int i = 0; i < wh_size; i++) {
    T tmp = static_cast<T>(
        fabs(static_cast<typename QuantizeDataType<T>::type>(in_current[i])));
    if (tmp > local_max_data) {
      local_max_data = tmp;
    }
  }
  shared_max_data[tid] = local_max_data;
  __syncthreads();

  int len = blockDim.x;
  for (int i = (len + 1) / 2; i > 0; len = i, i = (i + 1) / 2) {
    if (tid < i && tid + i < len &&
        shared_max_data[tid] < shared_max_data[tid + i]) {
      shared_max_data[tid] = shared_max_data[tid + i];
    }
    if (i == 1) {
      i = 0;  // break the loop
    }
    __syncthreads();
  }
  if (tid == 0 && shared_max_data[0] > out[bid]) {
    out[bid] = shared_max_data[0];
  }
}

template <typename Context, typename T>
void FindChannelAbsMaxFunctor<Context, T>::operator()(
    const Context &ctx,
    const DenseTensor &in_tensor,
    const int quant_axis,
    T *out_abs_max) {
  PADDLE_ENFORCE_EQ(
      quant_axis == 0 || quant_axis == 1,
      true,
      phi::errors::InvalidArgument("'quant_axis' should be 0 or 1, but "
                                   "the received is %d",
                                   quant_axis));
  const int num = in_tensor.numel();
  auto in_dims = in_tensor.dims();
  const T *in_data = in_tensor.data<T>();
  if (quant_axis == 0) {
    int cout = in_dims[0];
    int grid = cout;
    int block = 1024;
    FindChannelAbsMaxKernelQuantAxis0<T>
        <<<grid, block, block * sizeof(T), ctx.stream()>>>(
            in_data, num, cout, out_abs_max);
  } else if (quant_axis == 1) {
    int cin = in_dims[0];
    int cout = in_dims[1];
    int grid = cout;
    int max_threads = 1024;

#ifdef PADDLE_WITH_HIP
    hipMemset(out_abs_max, 0, sizeof(T) * cout);
#else
    cudaMemset(out_abs_max, 0, sizeof(T) * cout);
#endif  // PADDLE_FLUID_OPERATORS_FAKE_QUANTIZE_OP_CU_H_

    for (int i = 0; i < cin / max_threads; i++) {
      int block = max_threads;
      FindChannelAbsMaxKernelQuantAxis1<T>
          <<<grid, block, block * sizeof(T), ctx.stream()>>>(
              in_data, num, cin, cout, out_abs_max);
      in_data += cout * max_threads;
    }

    int block = cin % max_threads;
    if (block > 0) {
      FindChannelAbsMaxKernelQuantAxis1<T>
          <<<grid, block, block * sizeof(T), ctx.stream()>>>(
              in_data, num, in_dims[0], in_dims[1], out_abs_max);
    }
  }
}

// ChannelClipAndQuantKernel for quant_axis is 0
template <typename T>
__global__ void ChannelClipAndQuantKernelQuantAxis0(const T *in,
                                                    const T *scale,
                                                    const int bin_cnt,
                                                    const int round_type,
                                                    const int64_t n,
                                                    const int c,
                                                    T *out) {
  int tid = threadIdx.x;

  int64_t channel_size = n / c;
  const T *in_c = in + blockIdx.x * channel_size;
  T *out_c = out + blockIdx.x * channel_size;

  using ComputeDataType = typename QuantizeDataType<T>::type;

  ComputeDataType s = static_cast<ComputeDataType>(scale[blockIdx.x]);
  ComputeDataType inv_s = inverse(s);
  ComputeDataType bin_cnt_t = static_cast<ComputeDataType>(bin_cnt);

  for (int64_t i = tid; i < channel_size; i += blockDim.x) {
    ComputeDataType x = static_cast<ComputeDataType>(in_c[i]);
    if (round_type == 0) {
      x = bin_cnt_t * inv_s * x;
      x = roundWithTiesToEven(x);
      ComputeDataType max_bound = bin_cnt_t;
      ComputeDataType min_bound = -bin_cnt_t - static_cast<ComputeDataType>(1);
      x = x > max_bound ? max_bound : x;
      x = x < min_bound ? min_bound : x;
      out_c[i] = static_cast<T>(x);
    } else {
      ComputeDataType v = x > s ? s : x;
      v = v < -s ? -s : v;
      v = bin_cnt_t * inv_s * v;
      out_c[i] = static_cast<T>(round(v));
    }
  }
}

// ChannelClipAndQuantKernel for quant_axis is N
template <typename T>
__global__ void ChannelClipAndQuantKernelQuantAxisN(const T *in,
                                                    const T *scale,
                                                    const int bin_cnt,
                                                    const int round_type,
                                                    const int64_t n,
                                                    const int nScale,
                                                    const int quant_stride,
                                                    T *out) {
  int64_t idx = blockDim.x * blockIdx.x + threadIdx.x;
  using ComputeDataType = typename QuantizeDataType<T>::type;
  ComputeDataType bin_cnt_t = static_cast<ComputeDataType>(bin_cnt);
  for (int64_t i = idx; i < n; i += blockDim.x * gridDim.x) {
    ComputeDataType s =
        static_cast<ComputeDataType>(scale[(i / quant_stride) % nScale]);
    ComputeDataType inv_s = inverse(s);
    ComputeDataType x = static_cast<ComputeDataType>(in[i]);
    if (round_type == 0) {
      x = bin_cnt_t * inv_s * x;
      x = roundWithTiesToEven(x);
      ComputeDataType max_bound = bin_cnt_t;
      ComputeDataType min_bound = -bin_cnt_t - static_cast<ComputeDataType>(1);
      x = x > max_bound ? max_bound : x;
      x = x < min_bound ? min_bound : x;
      out[i] = static_cast<T>(x);
    } else {
      ComputeDataType v = x > s ? s : x;
      v = v < -s ? -s : v;
      v = bin_cnt_t * inv_s * v;
      out[i] = static_cast<T>(round(v));
    }
  }
}

template <typename Context, typename T>
void ChannelClipAndFakeQuantFunctor<Context, T>::operator()(
    const Context &ctx,
    const DenseTensor &in,
    const DenseTensor &scale,
    const int bin_cnt,
    const int round_type,
    const int quant_axis,
    DenseTensor *out) {
  int64_t num = in.numel();
  auto in_dims = in.dims();
  const T *in_data = in.data<T>();
  const T *scale_data = scale.data<T>();
  T *out_data = ctx.template Alloc<T>(out);

  if (quant_axis == 0) {
    int grid = in_dims[0];
    int block = 1024;
    ChannelClipAndQuantKernelQuantAxis0<T><<<grid, block, 0, ctx.stream()>>>(
        in_data, scale_data, bin_cnt, round_type, num, in_dims[0], out_data);
  } else {
    int quant_stride = 1;
    for (int i = quant_axis + 1; i < in_dims.size(); i++) {
      quant_stride *= in_dims[i];
    }
    int64_t block_size =
        std::min(num, static_cast<int64_t>(ctx.GetMaxThreadsPerBlock() / 4));
    int64_t max_threads = ctx.GetMaxPhysicalThreadCount();  // SM * block_per_SM
    const int64_t max_blocks =
        std::max(((max_threads - 1) / block_size + 1), static_cast<int64_t>(1));

    const int64_t grid_size =
        std::min(max_blocks, (num + block_size - 1) / block_size);

    ChannelClipAndQuantKernelQuantAxisN<T>
        <<<grid_size, block_size>>>(in_data,
                                    scale_data,
                                    bin_cnt,
                                    round_type,
                                    num,
                                    in_dims[quant_axis],
                                    quant_stride,
                                    out_data);
  }
}

// ChannelClipAndQuantDequantKernel for quant_axis is 0
template <typename T>
__global__ void ChannelClipAndQuantDequantKernelQuantAxis0(const T *in,
                                                           const T *scale,
                                                           const int bin_cnt,
                                                           const int round_type,
                                                           const int wh_size,
                                                           const int num,
                                                           const int cout,
                                                           T *out) {
  int64_t idx = blockDim.x * blockIdx.x + threadIdx.x;
  using ComputeDataType = typename QuantizeDataType<T>::type;
  ComputeDataType bin_cnt_t = static_cast<ComputeDataType>(bin_cnt);

  for (int64_t i = idx; i < num; i += blockDim.x * gridDim.x) {
    T s = scale[(i / wh_size) % cout];
    T inv_s = inverse(s);
    T x = in[i];
    if (round_type == 0) {
      x = bin_cnt * inv_s * x;
      x = roundWithTiesToEven(x);
      T max_bound = bin_cnt;
      T min_bound = -bin_cnt - static_cast<T>(1);
      x = x > max_bound ? max_bound : x;
      x = x < min_bound ? min_bound : x;
      out[i] = (x * s) / bin_cnt;
    } else {
      T v = x > s ? s : x;
      v = v < -s ? -s : v;
      v = bin_cnt * inv_s * v;
      out[i] = round(v) * s / bin_cnt;
    }
  }
}

// ChannelClipAndQuantDequantKernel for quant_axis is 1
template <typename T>
__global__ void ChannelClipAndQuantDequantKernelQuantAxis1(const T *in,
                                                           const T *scale,
                                                           const int bin_cnt,
                                                           const int round_type,
                                                           const int wh_size,
                                                           const int num,
                                                           const int cout,
                                                           T *out) {
  int64_t idx = blockDim.x * blockIdx.x + threadIdx.x;
  using ComputeDataType = typename QuantizeDataType<T>::type;
  ComputeDataType bin_cnt_t = static_cast<ComputeDataType>(bin_cnt);

  for (int64_t i = idx; i < num; i += blockDim.x * gridDim.x) {
    T s = scale[(i / wh_size) % cout];
    T inv_s = inverse(s);
    T x = in[i];
    if (round_type == 0) {
      x = bin_cnt * inv_s * x;
      x = roundWithTiesToEven(x);
      T max_bound = bin_cnt;
      T min_bound = -bin_cnt - static_cast<T>(1);
      x = x > max_bound ? max_bound : x;
      x = x < min_bound ? min_bound : x;
      out[i] = (x * s) / bin_cnt;
    } else {
      T v = x > s ? s : x;
      v = v < -s ? -s : v;
      v = bin_cnt * inv_s * v;
      out[i] = round(v) * s / bin_cnt;
    }
  }
}

template <typename Context, typename T>
void ChannelClipFakeQuantDequantFunctor<Context, T>::operator()(
    const Context &ctx,
    const DenseTensor &in,
    const DenseTensor &scale,
    const int bin_cnt,
    const int round_type,
    const int quant_axis,
    DenseTensor *out) {
  // At present, channelwise quantization supports conv2d, depthwise_conv2d
  // conv2d_transpose and mul

  int num = in.numel();
  auto in_dims = in.dims();

  const T *in_data = in.data<T>();
  const T *scale_data = scale.data<T>();
  T *out_data = ctx.template Alloc<T>(out);

  int64_t block_size =
      std::min(static_cast<int64_t>(num),
               static_cast<int64_t>(ctx.GetMaxThreadsPerBlock() / 4));

  int64_t max_threads = ctx.GetMaxPhysicalThreadCount();  // SM * block_per_SM
  const int64_t max_blocks =
      std::max(((max_threads - 1) / block_size + 1), static_cast<int64_t>(1));
  const int64_t grid_size =
      std::min(max_blocks, (num + block_size - 1) / block_size);

  if (quant_axis == 0) {
    const int window_size = num / in_dims[0];
    ChannelClipAndQuantDequantKernelQuantAxis0<T>
        <<<grid_size, block_size, 0, ctx.stream()>>>(in_data,
                                                     scale_data,
                                                     bin_cnt,
                                                     round_type,
                                                     window_size,
                                                     num,
                                                     in_dims[0],
                                                     out_data);
  } else if (quant_axis == 1) {
    const int window_size = num / (in_dims[0] * in_dims[1]);

    ChannelClipAndQuantDequantKernelQuantAxis1<T>
        <<<grid_size, block_size, 0, ctx.stream()>>>(in_data,
                                                     scale_data,
                                                     bin_cnt,
                                                     round_type,
                                                     window_size,
                                                     num,
                                                     in_dims[1],
                                                     out_data);
  }
}

template <typename Context, typename T>
void FindRangeAbsMaxFunctor<Context, T>::operator()(
    const Context &ctx,
    const DenseTensor &cur_scale,
    const DenseTensor &last_scale,
    const DenseTensor &iter,
    const int window_size,
    DenseTensor *scales_arr,
    DenseTensor *out_scale) {
  const auto gpu_place = ctx.GetPlace();
  T *scale_arr = ctx.template Alloc<T>(scales_arr);
  T *out_scale_data = ctx.template Alloc<T>(out_scale);

  phi::DenseTensor need_find_max, out_size;
  need_find_max.Resize({1});
  out_size.Resize({1});
  int *find_max = ctx.template Alloc<int>(&need_find_max);
  int *out_size_data = ctx.template Alloc<int>(&out_size);

  FindRangeAbsMaxAndFillArray<T>
      <<<1, 1, 0, ctx.stream()>>>(cur_scale.data<T>(),
                                  last_scale.data<T>(),
                                  iter.data<int64_t>(),
                                  window_size,
                                  scale_arr,
                                  out_scale_data,
                                  find_max,
                                  out_size_data);

  int g_find_max;
  memory_utils::Copy(phi::CPUPlace(),
                     &g_find_max,
                     gpu_place,
                     find_max,
                     sizeof(int),
                     ctx.stream());
  ctx.Wait();
  if (g_find_max) {
    int len;
    memory_utils::Copy(phi::CPUPlace(),
                       &len,
                       gpu_place,
                       out_size_data,
                       sizeof(int),
                       ctx.stream());
    ctx.Wait();
    phi::funcs::FindAbsMaxFunctor<phi::GPUContext, T>()(
        ctx, scale_arr, len, out_scale_data);
  }
}

template class FindAbsMaxFunctor<GPUContext, float16>;
template class FindAbsMaxFunctor<GPUContext, float>;
template class ClipAndFakeQuantFunctor<GPUContext, float16>;
template class ClipAndFakeQuantFunctor<GPUContext, float>;
template class FindMovingAverageAbsMaxFunctor<GPUContext, float16>;
template class FindMovingAverageAbsMaxFunctor<GPUContext, float>;
template class FindChannelAbsMaxFunctor<GPUContext, float16>;
template class FindChannelAbsMaxFunctor<GPUContext, float>;
template class ChannelClipAndFakeQuantFunctor<GPUContext, float16>;
template class ChannelClipAndFakeQuantFunctor<GPUContext, float>;
template class ChannelClipFakeQuantDequantFunctor<GPUContext, float>;
template class FindRangeAbsMaxFunctor<GPUContext, float16>;
template class FindRangeAbsMaxFunctor<GPUContext, float>;

}  // namespace funcs
}  // namespace phi
