/* Copyright (c) 2019 PaddlePaddle Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#include "paddle/fluid/operators/collective/c_reducescatter_op.h"

#include <memory>

namespace paddle {
namespace operators {

class CReduceScatterOp : public framework::OperatorWithKernel {
 public:
  using framework::OperatorWithKernel::OperatorWithKernel;

  void InferShape(framework::InferShapeContext *ctx) const override {
    OP_INOUT_CHECK(ctx->HasInput("X"), "Input", "X", "ReduceScatter");
    OP_INOUT_CHECK(ctx->HasOutput("Out"), "Output", "X", "ReduceScatter");
    int nranks = ctx->Attrs().Get<int>("nranks");
    phi::DDim dim = ctx->GetInputDim("X");
    if (dim[0] > 0 || dim[0] < -1) {
      PADDLE_ENFORCE_EQ(
          dim[0] % nranks,
          0,
          phi::errors::InvalidArgument(
              "dim[0] (%d) is not divisible by nranks(%d)", dim[0], nranks));
      dim[0] /= nranks;
    }
    ctx->SetOutputDim("Out", dim);
  }
};

class CReduceScatterOpMaker : public framework::OpProtoAndCheckerMaker {
 public:
  void Make() override {
    AddInput("X", "(Tensor) tensor to be allgather");
    AddOutput("Out", "(Tensor) the allgather result");
    AddAttr<int>("ring_id", "(int default 0) communication ring id.")
        .SetDefault(0);
    AddAttr<int>("nranks",
                 "Total trainer count of the distributed training job")
        .SetDefault(1);

    AddAttr<bool>(
        "use_calc_stream",
        "(bool default false) eject CUDA operations to calculation stream.")
        .SetDefault(false);
    AddComment(R"DOC(
CReduceScatter Operator

Reference: https://docs.nvidia.com/deeplearning/sdk/nccl-developer-guide/docs/usage/operations.html#reducescatter
)DOC");
  }
};

}  // namespace operators
}  // namespace paddle

namespace ops = paddle::operators;

REGISTER_OP_WITHOUT_GRADIENT(c_reducescatter,
                             ops::CReduceScatterOp,
                             ops::CReduceScatterOpMaker);

PD_REGISTER_STRUCT_KERNEL(c_reducescatter,
                          CPU,
                          ALL_LAYOUT,
                          ops::CReduceScatterOpCPUKernel,
                          float,
                          double,
                          int,
                          int64_t,
                          phi::dtype::float16) {}
