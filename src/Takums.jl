module Takums

import Base: AbstractFloat, Int, Int8, Int16, Int32, Int64, Integer, MPFR,
	Signed, Unsigned, reinterpret
import Printf
import Random: rand, randexp, AbstractRNG, Sampler

using libtakum_jll

export Takum8, Takum16, Takum32, Takum64, LinearTakum8, LinearTakum16,
       LinearTakum32, LinearTakum64, AnyTakum,
       NaRTakum8, NaRTakum16, NaRTakum32, NaRTakum64,
       NaRLinearTakum8, NaRLinearTakum16, NaRLinearTakum32, NaRLinearTakum64,
       takum, isnar

# type definitions
primitive type Takum8  <: AbstractFloat 8 end
primitive type Takum16 <: AbstractFloat 16 end
primitive type Takum32 <: AbstractFloat 32 end
primitive type Takum64 <: AbstractFloat 64 end

primitive type LinearTakum8  <: AbstractFloat 8 end
primitive type LinearTakum16 <: AbstractFloat 16 end
primitive type LinearTakum32 <: AbstractFloat 32 end
primitive type LinearTakum64 <: AbstractFloat 64 end

AnyTakum = Union{Takum8, Takum16, Takum32, Takum64, LinearTakum8,
                 LinearTakum16, LinearTakum32, LinearTakum64}
AnyTakum8 = Union{Takum8, LinearTakum8}
AnyTakum16 = Union{Takum16, LinearTakum16}
AnyTakum32 = Union{Takum32, LinearTakum32}
AnyTakum64 = Union{Takum64, LinearTakum64}

# NaR representations
const NaRTakum8  = Base.bitcast(Takum8,  0x80)
const NaRTakum16 = Base.bitcast(Takum16, 0x8000)
const NaRTakum32 = Base.bitcast(Takum32, 0x80000000)
const NaRTakum64 = Base.bitcast(Takum64, 0x8000000000000000)

const NaRLinearTakum8  = Base.bitcast(LinearTakum8,  0x80)
const NaRLinearTakum16 = Base.bitcast(LinearTakum16, 0x8000)
const NaRLinearTakum32 = Base.bitcast(LinearTakum32, 0x80000000)
const NaRLinearTakum64 = Base.bitcast(LinearTakum64, 0x8000000000000000)

# array takum types with their corresponding integer types for
# metaprogramming within the module
takum_types = [
	(:Takum8,        "takum8",         :Int8),
	(:Takum16,       "takum16",        :Int16),
	(:Takum32,       "takum32",        :Int32),
	(:Takum64,       "takum64",        :Int64),
	(:LinearTakum8,  "takum_linear8",  :Int8),
	(:LinearTakum16, "takum_linear16", :Int16),
	(:LinearTakum32, "takum_linear32", :Int32),
	(:LinearTakum64, "takum_linear64", :Int64),
]

# integer reinterpret casts
Base.reinterpret(::Type{Unsigned}, x::AnyTakum8)  = reinterpret(UInt8, x)
Base.reinterpret(::Type{Unsigned}, x::AnyTakum16) = reinterpret(UInt16, x)
Base.reinterpret(::Type{Unsigned}, x::AnyTakum32) = reinterpret(UInt32, x)
Base.reinterpret(::Type{Unsigned}, x::AnyTakum64) = reinterpret(UInt64, x)

Base.reinterpret(::Type{Signed}, x::AnyTakum8)  = reinterpret(Int8, x)
Base.reinterpret(::Type{Signed}, x::AnyTakum16) = reinterpret(Int16, x)
Base.reinterpret(::Type{Signed}, x::AnyTakum32) = reinterpret(Int32, x)
Base.reinterpret(::Type{Signed}, x::AnyTakum64) = reinterpret(Int64, x)

Base.uinttype(::Type{<:AnyTakum8})  = UInt8
Base.uinttype(::Type{<:AnyTakum16}) = UInt16
Base.uinttype(::Type{<:AnyTakum32}) = UInt32
Base.uinttype(::Type{<:AnyTakum64}) = UInt64

@static if VERSION ≥ v"1.10"
	Base.inttype(::Type{<:AnyTakum8})  = Int8
	Base.inttype(::Type{<:AnyTakum16}) = Int16
	Base.inttype(::Type{<:AnyTakum32}) = Int32
	Base.inttype(::Type{<:AnyTakum64}) = Int64
end

# the only floating-point property that makes sense to implement for logarithmic takums is signbit()
Base.signbit(t::AnyTakum8)  = (reinterpret(Unsigned, t) & 0x80) !== 0x00
Base.signbit(t::AnyTakum16) = (reinterpret(Unsigned, t) & 0x8000) !== 0x0000
Base.signbit(t::AnyTakum32) = (reinterpret(Unsigned, t) & 0x80000000) !== 0x00000000
Base.signbit(t::AnyTakum64) = (reinterpret(Unsigned, t) & 0x8000000000000000) !== 0x0000000000000000

# left undefined are sign_mask, exponent_mask, exponent_one, exponent_half,
# significand_mask, exponent_bias, exponent_bits, significand_bits,
# decompose, for now also for linear takums
#
# TODO cleaner, possibly limit to LinearTakums only
Base.exponent(t::AnyTakum) = exponent(Float64(t))
Base.significand(t::AnyTakum) = ldexp(t, -Base.exponent(t))
Base.ldexp(t::AnyTakum, e::Integer) = t * ((typeof(t))(2) .^ e)
function Base.frexp(t::AnyTakum)
	exp = isnan(t) ? 0 : (Base.exponent(t) + 1)
	x = ldexp(t, -exp)
	return (x, exp)
end

# decompose returns a triple (number, power, denominator) such that the
# original value is (number * (2^power) / denominator)
function Base.decompose(t::AnyTakum)::NTuple{3,Int}
	U = Base.uinttype(typeof(t))

	# cover special case
	if isnan(t)
		return U(0), 0, 0
	elseif t == zero(t)
		return U(0), 0, 1
	end

	# take the absolute value of the input takum so we can work
	# with the fraction directly
	tabs = abs(t)
	denominator = (t < zero(t)) ? -1 : 1

	# obtain the fraction bits by masking them out, set the
	# fraction_count'th bit, as it is the implicit bit we now need
	# to store explicitly
	fraction_count = precision(tabs) - 1
	number = reinterpret(U, tabs) & ((one(U) << fraction_count) - one(U))
	number |= one(U) << fraction_count

	# the power is the exponent minus the fraction bit count
	power = exponent(tabs) - fraction_count

	return number, power, denominator
end

# TODO implement decompose() for logarithmic takums separately

Base.iszero(t::AnyTakum8)  = reinterpret(Unsigned, t) === 0x00
Base.iszero(t::AnyTakum16) = reinterpret(Unsigned, t) === 0x0000
Base.iszero(t::AnyTakum32) = reinterpret(Unsigned, t) === 0x00000000
Base.iszero(t::AnyTakum64) = reinterpret(Unsigned, t) === 0x0000000000000000

Base.isone(t::AnyTakum8)  = reinterpret(Unsigned, t) === 0x40
Base.isone(t::AnyTakum16) = reinterpret(Unsigned, t) === 0x4000
Base.isone(t::AnyTakum32) = reinterpret(Unsigned, t) === 0x40000000
Base.isone(t::AnyTakum64) = reinterpret(Unsigned, t) === 0x4000000000000000

Base.isfinite(t::AnyTakum8)  = reinterpret(Unsigned, t) !== 0x80
Base.isfinite(t::AnyTakum16) = reinterpret(Unsigned, t) !== 0x8000
Base.isfinite(t::AnyTakum32) = reinterpret(Unsigned, t) !== 0x80000000
Base.isfinite(t::AnyTakum64) = reinterpret(Unsigned, t) !== 0x8000000000000000

Base.isnan(t::AnyTakum8)  = reinterpret(Unsigned, t) === 0x80
Base.isnan(t::AnyTakum16) = reinterpret(Unsigned, t) === 0x8000
Base.isnan(t::AnyTakum32) = reinterpret(Unsigned, t) === 0x80000000
Base.isnan(t::AnyTakum64) = reinterpret(Unsigned, t) === 0x8000000000000000

isnar(t::AnyTakum8)  = Base.isnan(t)
isnar(t::AnyTakum16) = Base.isnan(t)
isnar(t::AnyTakum32) = Base.isnan(t)
isnar(t::AnyTakum64) = Base.isnan(t)

Base.issubnormal(t::AnyTakum) = false
Base.ispow2(t::Union{Takum8, Takum16, Takum32, Takum64}) = Base.isone(t)
Base.ispow2(t::Union{LinearTakum8, LinearTakum16, LinearTakum32, LinearTakum64}) = Base.ispow2(Float64(t))
Base.iseven(t::Union{Takum8, Takum16, Takum32, Takum64}) = Base.iszero(t)
Base.iseven(t::Union{LinearTakum8, LinearTakum16, LinearTakum32, LinearTakum64}) = Base.iseven(Float64(t))
Base.isodd(t::Union{Takum8, Takum16, Takum32, Takum64}) = Base.isone(t) || Base.isone(-t)
Base.isodd(t::Union{LinearTakum8, LinearTakum16, LinearTakum32, LinearTakum64}) = Base.isodd(Float64(t))

# precision
_mantissa_bit_count(t::Takum8)  = @ccall libtakum.takum8_precision(reinterpret(Signed, t)::Int8)::UInt8
_mantissa_bit_count(t::Takum16) = @ccall libtakum.takum16_precision(reinterpret(Signed, t)::Int16)::UInt8
_mantissa_bit_count(t::Takum32) = @ccall libtakum.takum32_precision(reinterpret(Signed, t)::Int32)::UInt8
_mantissa_bit_count(t::Takum64) = @ccall libtakum.takum64_precision(reinterpret(Signed, t)::Int64)::UInt8
_mantissa_bit_count(t::LinearTakum8)  = @ccall libtakum.takum_linear8_precision(reinterpret(Signed, t)::Int8)::UInt8
_mantissa_bit_count(t::LinearTakum16) = @ccall libtakum.takum_linear16_precision(reinterpret(Signed, t)::Int16)::UInt8
_mantissa_bit_count(t::LinearTakum32) = @ccall libtakum.takum_linear32_precision(reinterpret(Signed, t)::Int32)::UInt8
_mantissa_bit_count(t::LinearTakum64) = @ccall libtakum.takum_linear64_precision(reinterpret(Signed, t)::Int64)::UInt8

function Base.precision(t::AnyTakum; base::Integer = 2)
	base > 1 || throw(DomainError(base, "`base` cannot be less than 2."))
	m = 1 + _mantissa_bit_count(t)
	return base == 2 ? Int(m) : floor(Int, m / log2(base))
end

# For the types we determine the precision of the zero of said type, as this returns
# the worst-case precision, consistent with what you obtain with the respective
# IEEE 754 precision functions
Base.precision(T::Type{<:AnyTakum}; base::Integer = 2) = precision(zero(T); base)

# eps (follow definition; for the types it is simply eps(Takum_(1.0))
Base.eps(t::AnyTakum)     = max(t - prevfloat(t), nextfloat(t) - t)
Base.eps(::Type{Takum8})  = Base.bitcast(Takum8,  0x2b)
Base.eps(::Type{Takum16}) = Base.bitcast(Takum16, 0x1f2f)
Base.eps(::Type{Takum32}) = Base.bitcast(Takum32, 0x160bc2b0)
Base.eps(::Type{Takum64}) = Base.bitcast(Takum64, 0x0d7a50987ab4d7df)
Base.eps(::Type{LinearTakum8})  = Base.bitcast(LinearTakum8,  0x30)
Base.eps(::Type{LinearTakum16}) = Base.bitcast(LinearTakum16, 0x2400)
Base.eps(::Type{LinearTakum32}) = Base.bitcast(LinearTakum32, 0x1a000000)
Base.eps(::Type{LinearTakum64}) = Base.bitcast(LinearTakum64, 0x1100000000000000)

# rounding
Base.round(t::AnyTakum) = typeof(t)(Base.round(Float64(t)))

Base.round(t::AnyTakum, r::RoundingMode{:ToZero})  = typeof(t)(Base.trunc(Float64(t)))
Base.round(t::AnyTakum, r::RoundingMode{:Down})    = typeof(t)(Base.floor(Float64(t)))
Base.round(t::AnyTakum, r::RoundingMode{:Up})      = typeof(t)(Base.ceil(Float64(t)))
Base.round(t::AnyTakum, r::RoundingMode{:Nearest}) = typeof(t)(Base.round(Float64(t)))

Base.trunc(t::AnyTakum) = Base.signbit(t) ? Base.ceil(t) : Base.floor(t)
Base.trunc(::Type{T}, t::AnyTakum) where {T <: Integer} = Base.trunc(T, Float64(t))

# type limits
Base.typemin(::Type{Takum8})  = NaRTakum8
Base.typemin(::Type{Takum16}) = NaRTakum16
Base.typemin(::Type{Takum32}) = NaRTakum32
Base.typemin(::Type{Takum64}) = NaRTakum64
Base.typemin(::Type{LinearTakum8})  = NaRLinearTakum8
Base.typemin(::Type{LinearTakum16}) = NaRLinearTakum16
Base.typemin(::Type{LinearTakum32}) = NaRLinearTakum32
Base.typemin(::Type{LinearTakum64}) = NaRLinearTakum64

Base.typemax(T::Type{<:AnyTakum8})  = Base.bitcast(T, 0x7f)
Base.typemax(T::Type{<:AnyTakum16}) = Base.bitcast(T, 0x7fff)
Base.typemax(T::Type{<:AnyTakum32}) = Base.bitcast(T, 0x7fffffff)
Base.typemax(T::Type{<:AnyTakum64}) = Base.bitcast(T, 0x7fffffffffffffff)

Base.floatmin(T::Type{<:AnyTakum8})  = Base.bitcast(T, 0x01)
Base.floatmin(T::Type{<:AnyTakum16}) = Base.bitcast(T, 0x0001)
Base.floatmin(T::Type{<:AnyTakum32}) = Base.bitcast(T, 0x00000001)
Base.floatmin(T::Type{<:AnyTakum64}) = Base.bitcast(T, 0x0000000000000001)

Base.floatmax(T::Type{<:AnyTakum8})  = Base.bitcast(T, 0x7f)
Base.floatmax(T::Type{<:AnyTakum16}) = Base.bitcast(T, 0x7fff)
Base.floatmax(T::Type{<:AnyTakum32}) = Base.bitcast(T, 0x7fffffff)
Base.floatmax(T::Type{<:AnyTakum64}) = Base.bitcast(T, 0x7fffffffffffffff)

Base.maxintfloat(::Type{T}) where {T<:Union{Takum8, Takum16, Takum32, Takum64}} = T(1.0)
Base.maxintfloat(::Type{LinearTakum8}) = LinearTakum8(2.0 ^ 3)
Base.maxintfloat(::Type{LinearTakum16}) = LinearTakum16(2.0 ^ 9)
Base.maxintfloat(::Type{LinearTakum32}) = LinearTakum32(2.0 ^ 24)
Base.maxintfloat(::Type{LinearTakum64}) = LinearTakum64(2.0 ^ 55)

# conversions from floating-point
Takum8(f::Float16) = Base.bitcast(Takum8, @ccall libtakum.takum8_from_float32(Float32(f)::Float32)::Int8)
Takum8(f::Float32) = Base.bitcast(Takum8, @ccall libtakum.takum8_from_float32(f::Float32)::Int8)
Takum8(f::Float64) = Base.bitcast(Takum8, @ccall libtakum.takum8_from_float64(f::Float64)::Int8)
LinearTakum8(f::Float16) = Base.bitcast(LinearTakum8, @ccall libtakum.takum_linear8_from_float32(Float32(f)::Float32)::Int8)
LinearTakum8(f::Float32) = Base.bitcast(LinearTakum8, @ccall libtakum.takum_linear8_from_float32(f::Float32)::Int8)
LinearTakum8(f::Float64) = Base.bitcast(LinearTakum8, @ccall libtakum.takum_linear8_from_float64(f::Float64)::Int8)

Takum16(f::Float16) = Base.bitcast(Takum16, @ccall libtakum.takum16_from_float32(Float32(f)::Float32)::Int16)
Takum16(f::Float32) = Base.bitcast(Takum16, @ccall libtakum.takum16_from_float32(f::Float32)::Int16)
Takum16(f::Float64) = Base.bitcast(Takum16, @ccall libtakum.takum16_from_float64(f::Float64)::Int16)
LinearTakum16(f::Float16) = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_from_float32(Float32(f)::Float32)::Int16)
LinearTakum16(f::Float32) = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_from_float32(f::Float32)::Int16)
LinearTakum16(f::Float64) = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_from_float64(f::Float64)::Int16)

Takum32(f::Float16) = Base.bitcast(Takum32, @ccall libtakum.takum32_from_float32(Float32(f)::Float32)::Int32)
Takum32(f::Float32) = Base.bitcast(Takum32, @ccall libtakum.takum32_from_float32(f::Float32)::Int32)
Takum32(f::Float64) = Base.bitcast(Takum32, @ccall libtakum.takum32_from_float64(f::Float64)::Int32)
LinearTakum32(f::Float16) = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_from_float32(Float32(f)::Float32)::Int32)
LinearTakum32(f::Float32) = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_from_float32(f::Float32)::Int32)
LinearTakum32(f::Float64) = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_from_float64(f::Float64)::Int32)

Takum64(f::Float16) = Base.bitcast(Takum64, @ccall libtakum.takum64_from_float32(Float32(f)::Float32)::Int64)
Takum64(f::Float32) = Base.bitcast(Takum64, @ccall libtakum.takum64_from_float32(f::Float32)::Int64)
Takum64(f::Float64) = Base.bitcast(Takum64, @ccall libtakum.takum64_from_float64(f::Float64)::Int64)
LinearTakum64(f::Float16) = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_from_float32(Float32(f)::Float32)::Int64)
LinearTakum64(f::Float32) = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_from_float32(f::Float32)::Int64)
LinearTakum64(f::Float64) = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_from_float64(f::Float64)::Int64)

# conversion from integers with promote rules
Takum8(i::Integer)  = Base.convert(Takum8,  Base.convert(Float64, i))
Takum16(i::Integer) = Base.convert(Takum16, Base.convert(Float64, i))
Takum32(i::Integer) = Base.convert(Takum32, Base.convert(Float64, i))
Takum64(i::Integer) = Base.convert(Takum64, Base.convert(Float64, i))
LinearTakum8(i::Integer)  = Base.convert(LinearTakum8,  Base.convert(Float64, i))
LinearTakum16(i::Integer) = Base.convert(LinearTakum16, Base.convert(Float64, i))
LinearTakum32(i::Integer) = Base.convert(LinearTakum32, Base.convert(Float64, i))
LinearTakum64(i::Integer) = Base.convert(LinearTakum64, Base.convert(Float64, i))
Base.promote_rule(T::Type{<:AnyTakum}, ::Type{<:Integer}) = T

# conversion from BigFloat
Takum8(f::BigFloat) = Takum8(Float64(f))
Takum16(f::BigFloat) = Takum16(Float64(f))
Takum32(f::BigFloat) = Takum32(Float64(f))
LinearTakum8(f::BigFloat) = LinearTakum8(Float64(f))
LinearTakum16(f::BigFloat) = LinearTakum16(Float64(f))
LinearTakum32(f::BigFloat) = LinearTakum32(Float64(f))

function LinearTakum64(f::BigFloat)
	if iszero(f)
		# truncated() is buggy when the input is zero
		return zero(LinearTakum64)
	else
		# take the absolute value so we are only working with
		# positive values, as only then can we directly transplant
		# the fraction bits
		fabs = abs(f)

		# first round the BigFloat to the maximum possible number
		# of takum fraction bits, namely 1 + (64 - 5) = 60, as
		# this possibly rounds the value and lets us obtain the
		# exponent for further processing
		f60 = BigFloat(fabs; precision = 60)

		# Build a raw takum with f60's exponent
		rawt = ldexp(one(LinearTakum64), exponent(f60))

		# Obtain the number of fraction bits the raw takum can
		# represent and round f60 down to this number of bits
		fprec = BigFloat(f; precision = precision(rawt))

		# During this process, fprec might have been rounded
		# insofar that the exponent changed, which would require
		# us to redo the whole process. We do it unconditionally,
		# so we take the exponent of fprec, update the raw
		# takum and round fprec accordingly to its capacity
		rawt = ldexp(one(LinearTakum64), exponent(fprec))
		fprec = BigFloat(fprec; precision = precision(rawt))

		# Now we have the raw takum, which we just need to fill
		# with fprec's fraction bits. For this we make use of
		# the Base.decompose() function, returning in the first
		# field an integer representing the fraction bits
		# (including the implicit 1-bit, shifted all the way
		# to the left).
		#
		# Given we limited the number of fraction bits, we can
		# safely convert this BigInt into UInt64, shift out the
		# implicit 1 bit and then shift it to the right such that
		# it's flush to the right.
		fraction = (UInt64(Base.decompose(fprec)[1]) << 1) >> (64 - (precision(rawt) - 1))

		# Combine raw takum and fraction
		result = Base.bitcast(LinearTakum64, Base.bitcast(UInt64, rawt) | fraction)

		# Return the result, negating it if f was negative
		return (f < 0) ? -result : result
	end
end

# TODO Conversion from BigFloat to Takum64

# conversion from irrational numbers
Takum8(i::AbstractIrrational) = Takum8(Float64(i))
Takum16(i::AbstractIrrational) = Takum16(Float64(i))
Takum32(i::AbstractIrrational) = Takum32(Float64(i))
Takum64(i::AbstractIrrational) = Takum64(Float64(i)) # TODO
LinearTakum8(i::AbstractIrrational) = LinearTakum8(Float64(i))
LinearTakum16(i::AbstractIrrational) = LinearTakum16(Float64(i))
LinearTakum32(i::AbstractIrrational) = LinearTakum32(Float64(i))
LinearTakum64(i::AbstractIrrational) = LinearTakum64(BigFloat(i; precision = 60))

# conversions to floating-point
Base.Float16(t::Takum8)  = Float16(@ccall libtakum.takum8_to_float32(reinterpret(Signed, t)::Int8)::Float32)
Base.Float16(t::Takum16) = Float16(@ccall libtakum.takum16_to_float32(reinterpret(Signed, t)::Int16)::Float32)
Base.Float16(t::Takum32) = Float16(@ccall libtakum.takum32_to_float32(reinterpret(Signed, t)::Int32)::Float32)
Base.Float16(t::Takum64) = Float16(@ccall libtakum.takum64_to_float32(reinterpret(Signed, t)::Int64)::Float32)
Base.Float16(t::LinearTakum8)  = Float16(@ccall libtakum.takum_linear8_to_float32(reinterpret(Signed, t)::Int8)::Float32)
Base.Float16(t::LinearTakum16) = Float16(@ccall libtakum.takum_linear16_to_float32(reinterpret(Signed, t)::Int16)::Float32)
Base.Float16(t::LinearTakum32) = Float16(@ccall libtakum.takum_linear32_to_float32(reinterpret(Signed, t)::Int32)::Float32)
Base.Float16(t::LinearTakum64) = Float16(@ccall libtakum.takum_linear64_to_float32(reinterpret(Signed, t)::Int64)::Float32)
Base.Float32(t::Takum8)  = @ccall libtakum.takum8_to_float32(reinterpret(Signed, t)::Int8)::Float32
Base.Float32(t::Takum16) = @ccall libtakum.takum16_to_float32(reinterpret(Signed, t)::Int16)::Float32
Base.Float32(t::Takum32) = @ccall libtakum.takum32_to_float32(reinterpret(Signed, t)::Int32)::Float32
Base.Float32(t::Takum64) = @ccall libtakum.takum64_to_float32(reinterpret(Signed, t)::Int64)::Float32
Base.Float32(t::LinearTakum8)  = @ccall libtakum.takum_linear8_to_float32(reinterpret(Signed, t)::Int8)::Float32
Base.Float32(t::LinearTakum16) = @ccall libtakum.takum_linear16_to_float32(reinterpret(Signed, t)::Int16)::Float32
Base.Float32(t::LinearTakum32) = @ccall libtakum.takum_linear32_to_float32(reinterpret(Signed, t)::Int32)::Float32
Base.Float32(t::LinearTakum64) = @ccall libtakum.takum_linear64_to_float32(reinterpret(Signed, t)::Int64)::Float32
Base.Float64(t::Takum8)  = @ccall libtakum.takum8_to_float64(reinterpret(Signed, t)::Int8)::Float64
Base.Float64(t::Takum16) = @ccall libtakum.takum16_to_float64(reinterpret(Signed, t)::Int16)::Float64
Base.Float64(t::Takum32) = @ccall libtakum.takum32_to_float64(reinterpret(Signed, t)::Int32)::Float64
Base.Float64(t::Takum64) = @ccall libtakum.takum64_to_float64(reinterpret(Signed, t)::Int64)::Float64
Base.Float64(t::LinearTakum8)  = @ccall libtakum.takum_linear8_to_float64(reinterpret(Signed, t)::Int8)::Float64
Base.Float64(t::LinearTakum16) = @ccall libtakum.takum_linear16_to_float64(reinterpret(Signed, t)::Int16)::Float64
Base.Float64(t::LinearTakum32) = @ccall libtakum.takum_linear32_to_float64(reinterpret(Signed, t)::Int32)::Float64
Base.Float64(t::LinearTakum64) = @ccall libtakum.takum_linear64_to_float64(reinterpret(Signed, t)::Int64)::Float64

# conversion to integer
Base.unsafe_trunc(T::Type{<:Integer}, t::AnyTakum)  = Base.unsafe_trunc(T, Float64(t))
Base.round(I::Type{<:Integer}, t::AnyTakum) = Base.round(I, Float64(t))

function (::Type{I})(t::Union{Takum8, Takum16, Takum32, Takum64}) where I <: Integer
	if t == -1
		return I(-1)
	elseif t == 0
		return I(0)
	elseif t == 1
		return I(1)
	else
		throw(InexactError(:round, I, t))
	end
end

function (::Type{I})(t::Union{LinearTakum8, LinearTakum16, LinearTakum32, LinearTakum64}) where I <: Integer
	# TODO test if integer is representable and return an InexactError if not
	return I(Float64(t))
end

# inter-takum conversions
Takum8(t::Takum16) = Base.bitcast(Takum8, @ccall libtakum.takum8_from_takum16(reinterpret(Signed, t)::Int16)::Int8)
Takum8(t::Takum32) = Base.bitcast(Takum8, @ccall libtakum.takum8_from_takum32(reinterpret(Signed, t)::Int32)::Int8)
Takum8(t::Takum64) = Base.bitcast(Takum8, @ccall libtakum.takum8_from_takum64(reinterpret(Signed, t)::Int64)::Int8)
Takum8(t::LinearTakum8) = Base.bitcast(Takum8, @ccall libtakum.takum8_from_takum_linear8(reinterpret(Signed, t)::Int8)::Int8)
Takum8(t::LinearTakum16) = Base.bitcast(Takum8, @ccall libtakum.takum8_from_takum_linear16(reinterpret(Signed, t)::Int16)::Int8)
Takum8(t::LinearTakum32) = Base.bitcast(Takum8, @ccall libtakum.takum8_from_takum_linear32(reinterpret(Signed, t)::Int32)::Int8)
Takum8(t::LinearTakum64) = Base.bitcast(Takum8, @ccall libtakum.takum8_from_takum_linear64(reinterpret(Signed, t)::Int64)::Int8)

Takum16(t::Takum8)  = Base.bitcast(Takum16, @ccall libtakum.takum16_from_takum8(reinterpret(Signed, t)::Int16)::Int16)
Takum16(t::Takum32) = Base.bitcast(Takum16, @ccall libtakum.takum16_from_takum32(reinterpret(Signed, t)::Int32)::Int16)
Takum16(t::Takum64) = Base.bitcast(Takum16, @ccall libtakum.takum16_from_takum64(reinterpret(Signed, t)::Int64)::Int16)
Takum16(t::LinearTakum8) = Base.bitcast(Takum16, @ccall libtakum.takum16_from_takum_linear8(reinterpret(Signed, t)::Int8)::Int16)
Takum16(t::LinearTakum16) = Base.bitcast(Takum16, @ccall libtakum.takum16_from_takum_linear16(reinterpret(Signed, t)::Int16)::Int16)
Takum16(t::LinearTakum32) = Base.bitcast(Takum16, @ccall libtakum.takum16_from_takum_linear32(reinterpret(Signed, t)::Int32)::Int16)
Takum16(t::LinearTakum64) = Base.bitcast(Takum16, @ccall libtakum.takum16_from_takum_linear64(reinterpret(Signed, t)::Int64)::Int16)

Takum32(t::Takum8)  = Base.bitcast(Takum32, @ccall libtakum.takum32_from_takum8(reinterpret(Signed, t)::Int8)::Int32)
Takum32(t::Takum16) = Base.bitcast(Takum32, @ccall libtakum.takum32_from_takum16(reinterpret(Signed, t)::Int16)::Int32)
Takum32(t::Takum64) = Base.bitcast(Takum32, @ccall libtakum.takum32_from_takum64(reinterpret(Signed, t)::Int64)::Int32)
Takum32(t::LinearTakum8) = Base.bitcast(Takum32, @ccall libtakum.takum32_from_takum_linear8(reinterpret(Signed, t)::Int8)::Int32)
Takum32(t::LinearTakum16) = Base.bitcast(Takum32, @ccall libtakum.takum32_from_takum_linear16(reinterpret(Signed, t)::Int16)::Int32)
Takum32(t::LinearTakum32) = Base.bitcast(Takum32, @ccall libtakum.takum32_from_takum_linear32(reinterpret(Signed, t)::Int32)::Int32)
Takum32(t::LinearTakum64) = Base.bitcast(Takum32, @ccall libtakum.takum32_from_takum_linear64(reinterpret(Signed, t)::Int64)::Int32)

Takum64(t::Takum8)  = Base.bitcast(Takum64, @ccall libtakum.takum64_from_takum8(reinterpret(Signed, t)::Int8)::Int64)
Takum64(t::Takum16) = Base.bitcast(Takum64, @ccall libtakum.takum64_from_takum16(reinterpret(Signed, t)::Int16)::Int64)
Takum64(t::Takum32) = Base.bitcast(Takum64, @ccall libtakum.takum64_from_takum32(reinterpret(Signed, t)::Int32)::Int64)
Takum64(t::LinearTakum8) = Base.bitcast(Takum64, @ccall libtakum.takum64_from_takum_linear8(reinterpret(Signed, t)::Int8)::Int64)
Takum64(t::LinearTakum16) = Base.bitcast(Takum64, @ccall libtakum.takum64_from_takum_linear16(reinterpret(Signed, t)::Int16)::Int64)
Takum64(t::LinearTakum32) = Base.bitcast(Takum64, @ccall libtakum.takum64_from_takum_linear32(reinterpret(Signed, t)::Int32)::Int64)
Takum64(t::LinearTakum64) = Base.bitcast(Takum64, @ccall libtakum.takum64_from_takum_linear64(reinterpret(Signed, t)::Int64)::Int64)

LinearTakum8(t::LinearTakum16) = Base.bitcast(LinearTakum8, @ccall libtakum.takum_linear8_from_takum_linear16(reinterpret(Signed, t)::Int16)::Int8)
LinearTakum8(t::LinearTakum32) = Base.bitcast(LinearTakum8, @ccall libtakum.takum_linear8_from_takum_linear32(reinterpret(Signed, t)::Int32)::Int8)
LinearTakum8(t::LinearTakum64) = Base.bitcast(LinearTakum8, @ccall libtakum.takum_linear8_from_takum_linear64(reinterpret(Signed, t)::Int64)::Int8)
LinearTakum8(t::Takum8) = Base.bitcast(LinearTakum8, @ccall libtakum.takum_linear8_from_takum8(reinterpret(Signed, t)::Int8)::Int8)
LinearTakum8(t::Takum16) = Base.bitcast(LinearTakum8, @ccall libtakum.takum_linear8_from_takum16(reinterpret(Signed, t)::Int16)::Int8)
LinearTakum8(t::Takum32) = Base.bitcast(LinearTakum8, @ccall libtakum.takum_linear8_from_takum32(reinterpret(Signed, t)::Int32)::Int8)
LinearTakum8(t::Takum64) = Base.bitcast(LinearTakum8, @ccall libtakum.takum_linear8_from_takum64(reinterpret(Signed, t)::Int64)::Int8)

LinearTakum16(t::LinearTakum8)  = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_from_takum_linear8(reinterpret(Signed, t)::Int8)::Int16)
LinearTakum16(t::LinearTakum32) = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_from_takum_linear32(reinterpret(Signed, t)::Int32)::Int16)
LinearTakum16(t::LinearTakum64) = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_from_takum_linear64(reinterpret(Signed, t)::Int64)::Int16)
LinearTakum16(t::Takum8) = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_from_takum8(reinterpret(Signed, t)::Int8)::Int16)
LinearTakum16(t::Takum16) = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_from_takum16(reinterpret(Signed, t)::Int16)::Int16)
LinearTakum16(t::Takum32) = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_from_takum32(reinterpret(Signed, t)::Int32)::Int16)
LinearTakum16(t::Takum64) = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_from_takum64(reinterpret(Signed, t)::Int64)::Int16)

LinearTakum32(t::LinearTakum8)  = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_from_takum_linear8(reinterpret(Signed, t)::Int8)::Int32)
LinearTakum32(t::LinearTakum16) = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_from_takum_linear16(reinterpret(Signed, t)::Int16)::Int32)
LinearTakum32(t::LinearTakum64) = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_from_takum_linear64(reinterpret(Signed, t)::Int64)::Int32)
LinearTakum32(t::Takum8) = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_from_takum8(reinterpret(Signed, t)::Int8)::Int32)
LinearTakum32(t::Takum16) = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_from_takum16(reinterpret(Signed, t)::Int16)::Int32)
LinearTakum32(t::Takum32) = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_from_takum32(reinterpret(Signed, t)::Int32)::Int32)
LinearTakum32(t::Takum64) = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_from_takum64(reinterpret(Signed, t)::Int64)::Int32)

LinearTakum64(t::LinearTakum8)  = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_from_takum_linear8(reinterpret(Signed, t)::Int8)::Int64)
LinearTakum64(t::LinearTakum16) = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_from_takum_linear16(reinterpret(Signed, t)::Int16)::Int64)
LinearTakum64(t::LinearTakum32) = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_from_takum_linear32(reinterpret(Signed, t)::Int32)::Int64)
LinearTakum64(t::Takum8)  = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_from_takum8(reinterpret(Signed, t)::Int8)::Int64)
LinearTakum64(t::Takum16) = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_from_takum16(reinterpret(Signed, t)::Int16)::Int64)
LinearTakum64(t::Takum32) = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_from_takum32(reinterpret(Signed, t)::Int32)::Int64)
LinearTakum64(t::Takum64) = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_from_takum64(reinterpret(Signed, t)::Int64)::Int64)

# inter-takum promote rules
Base.promote_rule(::Type{Takum16}, ::Type{Takum8}) = Takum16
Base.promote_rule(::Type{LinearTakum16}, ::Type{LinearTakum8}) = LinearTakum16

Base.promote_rule(::Type{Takum32}, ::Type{Takum8}) = Takum32
Base.promote_rule(::Type{Takum32}, ::Type{Takum16}) = Takum32
Base.promote_rule(::Type{LinearTakum32}, ::Type{LinearTakum8}) = LinearTakum32
Base.promote_rule(::Type{LinearTakum32}, ::Type{LinearTakum16}) = LinearTakum32

Base.promote_rule(::Type{Takum64}, ::Type{Takum8}) = Takum64
Base.promote_rule(::Type{Takum64}, ::Type{Takum16}) = Takum64
Base.promote_rule(::Type{Takum64}, ::Type{Takum32}) = Takum64
Base.promote_rule(::Type{LinearTakum64}, ::Type{LinearTakum8}) = LinearTakum64
Base.promote_rule(::Type{LinearTakum64}, ::Type{LinearTakum16}) = LinearTakum64
Base.promote_rule(::Type{LinearTakum64}, ::Type{LinearTakum32}) = LinearTakum64

# IEEE 754 floating point promote rules, where we expand all to Float64
# given we would otherwise constrain the dynamic range
Base.promote_rule(::Type{Float16}, ::Type{<:AnyTakum}) = Float64
Base.promote_rule(::Type{Float32}, ::Type{<:AnyTakum}) = Float64
Base.promote_rule(::Type{Float64}, ::Type{<:AnyTakum}) = Float64

# arithmetic
Base.:(+)(x::Takum8,  y::Takum8)  = Base.bitcast(Takum8,  @ccall libtakum.takum8_addition(reinterpret(Signed, x)::Int8, reinterpret(Signed, y)::Int8)::Int8)
Base.:(+)(x::Takum16, y::Takum16) = Base.bitcast(Takum16, @ccall libtakum.takum16_addition(reinterpret(Signed, x)::Int16, reinterpret(Signed, y)::Int16)::Int16)
Base.:(+)(x::Takum32, y::Takum32) = Base.bitcast(Takum32, @ccall libtakum.takum32_addition(reinterpret(Signed, x)::Int32, reinterpret(Signed, y)::Int32)::Int32)
Base.:(+)(x::Takum64, y::Takum64) = Base.bitcast(Takum64, @ccall libtakum.takum64_addition(reinterpret(Signed, x)::Int64, reinterpret(Signed, y)::Int64)::Int64)
Base.:(+)(x::LinearTakum8,  y::LinearTakum8)  = Base.bitcast(LinearTakum8,  @ccall libtakum.takum_linear8_addition(reinterpret(Signed, x)::Int8, reinterpret(Signed, y)::Int8)::Int8)
Base.:(+)(x::LinearTakum16, y::LinearTakum16) = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_addition(reinterpret(Signed, x)::Int16, reinterpret(Signed, y)::Int16)::Int16)
Base.:(+)(x::LinearTakum32, y::LinearTakum32) = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_addition(reinterpret(Signed, x)::Int32, reinterpret(Signed, y)::Int32)::Int32)
Base.:(+)(x::LinearTakum64, y::LinearTakum64) = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_addition(reinterpret(Signed, x)::Int64, reinterpret(Signed, y)::Int64)::Int64)

Base.:(-)(x::Takum8,  y::Takum8)  = Base.bitcast(Takum8,  @ccall libtakum.takum8_subtraction(reinterpret(Signed, x)::Int8, reinterpret(Signed, y)::Int8)::Int8)
Base.:(-)(x::Takum16, y::Takum16) = Base.bitcast(Takum16, @ccall libtakum.takum16_subtraction(reinterpret(Signed, x)::Int16, reinterpret(Signed, y)::Int16)::Int16)
Base.:(-)(x::Takum32, y::Takum32) = Base.bitcast(Takum32, @ccall libtakum.takum32_subtraction(reinterpret(Signed, x)::Int32, reinterpret(Signed, y)::Int32)::Int32)
Base.:(-)(x::Takum64, y::Takum64) = Base.bitcast(Takum64, @ccall libtakum.takum64_subtraction(reinterpret(Signed, x)::Int64, reinterpret(Signed, y)::Int64)::Int64)
Base.:(-)(x::LinearTakum8,  y::LinearTakum8)  = Base.bitcast(LinearTakum8,  @ccall libtakum.takum_linear8_subtraction(reinterpret(Signed, x)::Int8, reinterpret(Signed, y)::Int8)::Int8)
Base.:(-)(x::LinearTakum16, y::LinearTakum16) = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_subtraction(reinterpret(Signed, x)::Int16, reinterpret(Signed, y)::Int16)::Int16)
Base.:(-)(x::LinearTakum32, y::LinearTakum32) = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_subtraction(reinterpret(Signed, x)::Int32, reinterpret(Signed, y)::Int32)::Int32)
Base.:(-)(x::LinearTakum64, y::LinearTakum64) = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_subtraction(reinterpret(Signed, x)::Int64, reinterpret(Signed, y)::Int64)::Int64)

Base.:(*)(x::Takum8,  y::Takum8)  = Base.bitcast(Takum8,  @ccall libtakum.takum8_multiplication(reinterpret(Signed, x)::Int8, reinterpret(Signed, y)::Int8)::Int8)
Base.:(*)(x::Takum16, y::Takum16) = Base.bitcast(Takum16, @ccall libtakum.takum16_multiplication(reinterpret(Signed, x)::Int16, reinterpret(Signed, y)::Int16)::Int16)
Base.:(*)(x::Takum32, y::Takum32) = Base.bitcast(Takum32, @ccall libtakum.takum32_multiplication(reinterpret(Signed, x)::Int32, reinterpret(Signed, y)::Int32)::Int32)
Base.:(*)(x::Takum64, y::Takum64) = Base.bitcast(Takum64, @ccall libtakum.takum64_multiplication(reinterpret(Signed, x)::Int64, reinterpret(Signed, y)::Int64)::Int64)
Base.:(*)(x::LinearTakum8,  y::LinearTakum8)  = Base.bitcast(LinearTakum8,  @ccall libtakum.takum_linear8_multiplication(reinterpret(Signed, x)::Int8, reinterpret(Signed, y)::Int8)::Int8)
Base.:(*)(x::LinearTakum16, y::LinearTakum16) = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_multiplication(reinterpret(Signed, x)::Int16, reinterpret(Signed, y)::Int16)::Int16)
Base.:(*)(x::LinearTakum32, y::LinearTakum32) = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_multiplication(reinterpret(Signed, x)::Int32, reinterpret(Signed, y)::Int32)::Int32)
Base.:(*)(x::LinearTakum64, y::LinearTakum64) = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_multiplication(reinterpret(Signed, x)::Int64, reinterpret(Signed, y)::Int64)::Int64)

Base.:(/)(x::Takum8,  y::Takum8)  = Base.bitcast(Takum8,  @ccall libtakum.takum8_division(reinterpret(Signed, x)::Int8, reinterpret(Signed, y)::Int8)::Int8)
Base.:(/)(x::Takum16, y::Takum16) = Base.bitcast(Takum16, @ccall libtakum.takum16_division(reinterpret(Signed, x)::Int16, reinterpret(Signed, y)::Int16)::Int16)
Base.:(/)(x::Takum32, y::Takum32) = Base.bitcast(Takum32, @ccall libtakum.takum32_division(reinterpret(Signed, x)::Int32, reinterpret(Signed, y)::Int32)::Int32)
Base.:(/)(x::Takum64, y::Takum64) = Base.bitcast(Takum64, @ccall libtakum.takum64_division(reinterpret(Signed, x)::Int64, reinterpret(Signed, y)::Int64)::Int64)
Base.:(/)(x::LinearTakum8,  y::LinearTakum8)  = Base.bitcast(LinearTakum8,  @ccall libtakum.takum_linear8_division(reinterpret(Signed, x)::Int8, reinterpret(Signed, y)::Int8)::Int8)
Base.:(/)(x::LinearTakum16, y::LinearTakum16) = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_division(reinterpret(Signed, x)::Int16, reinterpret(Signed, y)::Int16)::Int16)
Base.:(/)(x::LinearTakum32, y::LinearTakum32) = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_division(reinterpret(Signed, x)::Int32, reinterpret(Signed, y)::Int32)::Int32)
Base.:(/)(x::LinearTakum64, y::LinearTakum64) = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_division(reinterpret(Signed, x)::Int64, reinterpret(Signed, y)::Int64)::Int64)

Base.:(^)(x::Takum8,  y::Takum8)  = Base.bitcast(Takum8,  @ccall libtakum.takum8_power(reinterpret(Signed, x)::Int8, reinterpret(Signed, y)::Int8)::Int8)
Base.:(^)(x::Takum16, y::Takum16) = Base.bitcast(Takum16, @ccall libtakum.takum16_power(reinterpret(Signed, x)::Int16, reinterpret(Signed, y)::Int16)::Int16)
Base.:(^)(x::Takum32, y::Takum32) = Base.bitcast(Takum32, @ccall libtakum.takum32_power(reinterpret(Signed, x)::Int32, reinterpret(Signed, y)::Int32)::Int32)
Base.:(^)(x::Takum64, y::Takum64) = Base.bitcast(Takum64, @ccall libtakum.takum64_power(reinterpret(Signed, x)::Int64, reinterpret(Signed, y)::Int64)::Int64)
Base.:(^)(x::LinearTakum8,  y::LinearTakum8)  = Base.bitcast(LinearTakum8,  @ccall libtakum.takum_linear8_power(reinterpret(Signed, x)::Int8, reinterpret(Signed, y)::Int8)::Int8)
Base.:(^)(x::LinearTakum16, y::LinearTakum16) = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_power(reinterpret(Signed, x)::Int16, reinterpret(Signed, y)::Int16)::Int16)
Base.:(^)(x::LinearTakum32, y::LinearTakum32) = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_power(reinterpret(Signed, x)::Int32, reinterpret(Signed, y)::Int32)::Int32)
Base.:(^)(x::LinearTakum64, y::LinearTakum64) = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_power(reinterpret(Signed, x)::Int64, reinterpret(Signed, y)::Int64)::Int64)

Base.:(^)(x::Takum8,  n::Integer) = Base.bitcast(Takum8,  @ccall libtakum.takum8_integer_power(reinterpret(Signed, x)::Int8, n::Int64)::Int8)
Base.:(^)(x::Takum16, n::Integer) = Base.bitcast(Takum16, @ccall libtakum.takum16_integer_power(reinterpret(Signed, x)::Int16, n::Int64)::Int16)
Base.:(^)(x::Takum32, n::Integer) = Base.bitcast(Takum32, @ccall libtakum.takum32_integer_power(reinterpret(Signed, x)::Int32, n::Int64)::Int32)
Base.:(^)(x::Takum64, n::Integer) = Base.bitcast(Takum64, @ccall libtakum.takum64_integer_power(reinterpret(Signed, x)::Int64, n::Int64)::Int64)
Base.:(^)(x::LinearTakum8,  n::Integer) = Base.bitcast(LinearTakum8,  @ccall libtakum.takum_linear8_integer_power(reinterpret(Signed, x)::Int8, n::Int64)::Int8)
Base.:(^)(x::LinearTakum16, n::Integer) = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_integer_power(reinterpret(Signed, x)::Int16, n::Int64)::Int16)
Base.:(^)(x::LinearTakum32, n::Integer) = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_integer_power(reinterpret(Signed, x)::Int32, n::Int64)::Int32)
Base.:(^)(x::LinearTakum64, n::Integer) = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_integer_power(reinterpret(Signed, x)::Int64, n::Int64)::Int64)

Base.:(-)(t::AnyTakum) = Base.bitcast(typeof(t), -reinterpret(Signed, t))

Base.zero(T::Type{<:AnyTakum8})  = Base.bitcast(T, 0x00)
Base.zero(T::Type{<:AnyTakum16}) = Base.bitcast(T, 0x0000)
Base.zero(T::Type{<:AnyTakum32}) = Base.bitcast(T, 0x00000000)
Base.zero(T::Type{<:AnyTakum64}) = Base.bitcast(T, 0x0000000000000000)

Base.one(T::Type{<:AnyTakum8})  = Base.bitcast(T, 0x40)
Base.one(T::Type{<:AnyTakum16}) = Base.bitcast(T, 0x4000)
Base.one(T::Type{<:AnyTakum32}) = Base.bitcast(T, 0x40000000)
Base.one(T::Type{<:AnyTakum64}) = Base.bitcast(T, 0x4000000000000000)

Base.inv(t::Takum8) = Base.bitcast(Takum8,  @ccall libtakum.takum8_inversion(reinterpret(Signed, t)::Int8)::Int8)
Base.inv(t::Takum16) = Base.bitcast(Takum16,  @ccall libtakum.takum16_inversion(reinterpret(Signed, t)::Int16)::Int16)
Base.inv(t::Takum32) = Base.bitcast(Takum32,  @ccall libtakum.takum32_inversion(reinterpret(Signed, t)::Int32)::Int32)
Base.inv(t::Takum64) = Base.bitcast(Takum64,  @ccall libtakum.takum64_inversion(reinterpret(Signed, t)::Int64)::Int64)
Base.inv(t::LinearTakum8) = Base.bitcast(LinearTakum8,  @ccall libtakum.takum_linear8_inversion(reinterpret(Signed, t)::Int8)::Int8)
Base.inv(t::LinearTakum16) = Base.bitcast(LinearTakum16,  @ccall libtakum.takum_linear16_inversion(reinterpret(Signed, t)::Int16)::Int16)
Base.inv(t::LinearTakum32) = Base.bitcast(LinearTakum32,  @ccall libtakum.takum_linear32_inversion(reinterpret(Signed, t)::Int32)::Int32)
Base.inv(t::LinearTakum64) = Base.bitcast(LinearTakum64,  @ccall libtakum.takum_linear64_inversion(reinterpret(Signed, t)::Int64)::Int64)

# comparisons
Base.:(==)(x::T, y::T) where {T <: AnyTakum} = reinterpret(Signed, x) == reinterpret(Signed, y)
Base.:(!=)(x::T, y::T) where {T <: AnyTakum} = reinterpret(Signed, x) != reinterpret(Signed, y)
Base.:(<)(x::T, y::T) where {T <: AnyTakum} = reinterpret(Signed, x) < reinterpret(Signed, y)
Base.:(<=)(x::T, y::T) where {T <: AnyTakum} = reinterpret(Signed, x) <= reinterpret(Signed, y)

Base.isequal(x::T, y::T) where {T <: AnyTakum} = (x == y)

# TODO: widen for 64-bit to BigFloat
Base.widen(::Type{Takum8}) = Takum16
Base.widen(::Type{Takum16}) = Takum32
Base.widen(::Type{Takum32}) = Takum64
Base.widen(::Type{LinearTakum8}) = LinearTakum16
Base.widen(::Type{LinearTakum16}) = LinearTakum32
Base.widen(::Type{LinearTakum32}) = LinearTakum64

Base.widemul(x::Union{Takum8, Takum16, Takum32}, y::Union{Takum8, Takum16, Takum32}) = Basen.widen(x) * Base.widen(y)
Base.widemul(x::Union{LinearTakum8, LinearTakum16, LinearTakum32}, y::Union{LinearTakum8, LinearTakum16, LinearTakum32}) = Basen.widen(x) * Base.widen(y)

# output
function Base.show(io::IO, t::AnyTakum)
	has_type_info = typeof(t) === Base.get(io, :typeinfo, Any)
	if isnar(t)
		Base.print(io, "NaR", string(typeof(t)))
	else
		has_type_info || Base.print(io, string(typeof(t)) * "(")
		@static if VERSION ≥ v"1.10"
			@Printf.printf(IOContext(io, :typeinfo=>typeof(t)), "%.*g", max(4, 1 + Base.precision(t; base = 10)), Float64(t))
		else
			@Printf.printf(IOContext(io, :typeinfo=>typeof(t)), "%f", Float64(t))
		end
		has_type_info || Base.print(io, ")")
	end
end

Printf.tofloat(t::AnyTakum) = Float64(t)

# bitstring
Base.bitstring(t::AnyTakum) = Base.bitstring(reinterpret(Unsigned, t))

# next and previous number
function Base.nextfloat(t::AnyTakum, n::Integer)
	# preserve NaR
	if isnar(t)
		return t
	end

	# convert t to its integral representation
	t_integer = reinterpret(Signed, t)

	# set result to NaR and catch valid cases later
	result_integer = typemin(t_integer)

	# check if adding n would under- or overflow, return NaR otherwise
	if (n >= 0 && t_integer <= reinterpret(Signed, typemax(t)) - n) ||
	   (n < 0 && t_integer >= reinterpret(Signed, typemin(t)) + (-n))
		result_integer = typeof(t_integer)(t_integer + n)
	end

	return Base.bitcast(typeof(t), result_integer)
end
Base.prevfloat(t::AnyTakum, n::Integer) = Base.nextfloat(t, -n)

Base.nextfloat(t::AnyTakum) = Base.nextfloat(t, 1)
Base.prevfloat(t::AnyTakum) = Base.prevfloat(t, 1)

# math functions
Base.abs(t::AnyTakum) = (t < 0) ? -t : t
Base.abs2(t::AnyTakum) = t * t

# 2-argument arctangent
Base.atan(x::Takum8,  y::Takum8)  = Base.bitcast(Takum8,  @ccall libtakum.takum8_arctan2(reinterpret(Signed, x)::Int8, reinterpret(Signed, y)::Int8)::Int8)
Base.atan(x::Takum16, y::Takum16) = Base.bitcast(Takum16, @ccall libtakum.takum16_arctan2(reinterpret(Signed, x)::Int16, reinterpret(Signed, y)::Int16)::Int16)
Base.atan(x::Takum32, y::Takum32) = Base.bitcast(Takum32, @ccall libtakum.takum32_arctan2(reinterpret(Signed, x)::Int32, reinterpret(Signed, y)::Int32)::Int32)
Base.atan(x::Takum64, y::Takum64) = Base.bitcast(Takum64, @ccall libtakum.takum64_arctan2(reinterpret(Signed, x)::Int64, reinterpret(Signed, y)::Int64)::Int64)
Base.atan(x::LinearTakum8,  y::LinearTakum8)  = Base.bitcast(LinearTakum8,  @ccall libtakum.takum_linear8_arctan2(reinterpret(Signed, x)::Int8, reinterpret(Signed, y)::Int8)::Int8)
Base.atan(x::LinearTakum16, y::LinearTakum16) = Base.bitcast(LinearTakum16, @ccall libtakum.takum_linear16_arctan2(reinterpret(Signed, x)::Int16, reinterpret(Signed, y)::Int16)::Int16)
Base.atan(x::LinearTakum32, y::LinearTakum32) = Base.bitcast(LinearTakum32, @ccall libtakum.takum_linear32_arctan2(reinterpret(Signed, x)::Int32, reinterpret(Signed, y)::Int32)::Int32)
Base.atan(x::LinearTakum64, y::LinearTakum64) = Base.bitcast(LinearTakum64, @ccall libtakum.takum_linear64_arctan2(reinterpret(Signed, x)::Int64, reinterpret(Signed, y)::Int64)::Int64)

math_functions = [
	(:acos,  :arccos),
	(:acosh, :arcosh),
	(:acot,  :arccot),
	(:acoth, :arcoth),
	(:acsc,  :arccsc),
	(:acsch, :arcsch),
	(:asec,  :arcsec),
	(:asech, :arsech),
	(:asin,  :arcsin),
	(:asinh, :arsinh),
	(:atan,  :arctan),
	(:atanh, :artanh),
	(:cbrt,  :root, :(3::Int64)),
	(:cos,   :cos),
	(:cospi, :cos_pi_times),
	(:cosh,  :cosh),
	(:cot,   :cot),
	(:coth,  :coth),
	(:csc,   :csc),
	(:csch,  :csch),
	(:exp,   :exp),
	(:exp10, :(10_raised)),
	(:exp2,  :(2_raised)),
	(:expm1, :exp_minus_1),
	(:log,   :ln),
	(:log10, :lg),
	(:log1p, :ln_1_plus),
	(:log2,  :lb),
	(:sec,   :sec),
	(:sech,  :sech),
	(:sin,   :sin),
	(:sinpi, :sin_pi_times),
	(:sinh,  :sinh),
	(:sqrt,  :square_root),
	(:tan,   :tan),
	(:tanh,  :tanh),
]

@static if VERSION ≥ v"1.10"
	push!(math_functions, (:tanpi, :tan_pi_times))
end

for (takum_type, takum_type_cname, takum_integer_type) in takum_types
	for (math_function, library_math_function, arguments...) in math_functions
		@eval begin
			Base.$math_function(t::$takum_type) = Base.bitcast($takum_type,
				@ccall libtakum.$(Symbol(takum_type_cname, "_", library_math_function))(
				reinterpret(Signed, t)::$takum_integer_type, $(arguments...))::$takum_integer_type)
		end
	end
end

# random
rand(rng::AbstractRNG, ::Sampler{T}) where {T <: AnyTakum8} = T(rand(rng, Float64))
rand(rng::AbstractRNG, ::Sampler{T}) where {T <: AnyTakum16} = T(rand(rng, Float64))
rand(rng::AbstractRNG, ::Sampler{T}) where {T <: AnyTakum32} = T(rand(rng, Float64))
rand(rng::AbstractRNG, ::Sampler{Takum64}) = Takum64(rand(rng, Float64)) # TODO
rand(rng::AbstractRNG, ::Sampler{LinearTakum64}) = setprecision(BigFloat, 60) do; LinearTakum64(rand(rng, BigFloat)) end

randexp(rng::AbstractRNG, ::Sampler{T}) where {T <: AnyTakum8} = T(randexp(rng, Float64))
randexp(rng::AbstractRNG, ::Sampler{T}) where {T <: AnyTakum16} = T(randexp(rng, Float64))
randexp(rng::AbstractRNG, ::Sampler{T}) where {T <: AnyTakum32} = T(randexp(rng, Float64))
randexp(rng::AbstractRNG, ::Sampler{Takum64}) = Takum64(randexp(rng, Float64)) # TODO
randexp(rng::AbstractRNG, ::Sampler{LinearTakum64}) = setprecision(BigFloat, 60) do; LinearTakum64(randexp(rng, BigFloat)) end

# miscellaneous
Base.bswap(t::AnyTakum) = Base.bswap_int(t)

# TODO: muladd?, rem?, mod?, random, isinf alias of isfinite?, takum?

end
