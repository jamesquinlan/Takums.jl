# Takums.jl

[![Build Status](https://github.com/takum-arithmetic/Takums.jl/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/takum-arithmetic/Takums.jl/actions/workflows/CI.yml?query=branch%3Amaster)

This package implements [takum arithmetic](https://arxiv.org/abs/2404.18603), a new tapered
precision machine number format. Four new data types are defined, namely
`Takum8`, `Takum16`, `Takum32` and `Takum64`. Internally the reference C99 library
[libtakum](https://github.com/takum-arithmetic/libtakum) is used for the
actual computations for the most part.

Using this package one is able to evaluate takums for real-world applications
in terms of precision. Given it is a software implementation the performance
is overall worse than the respective usual IEEE 754 floating-point hardware
implementations.

## Usage

The four takum number types `Takum8`, `Takum16`, `Takum32` and `Takum64`
have been implemented to behave as much as any built-in floating-point
type. They are subtypes of `AbstractFloat` even though takum itself
is strictly speaking not a floating-point number format, but a
logarithmic number system. However, as the majority of numerical code is
written to accept `AbstractFloat`s rather than `Real`s and takums share
many properties of a typical floating-point number system, this decision
was made deliberately and for good reasons.

```julia
julia> using Takums

julia> x = Takum8(4.0)
Takum8(3.955)

julia> sqrt(x)
Takum8(2.117)
```

If you find a floating-point function you need that is not yet implemented,
please raise an issue.