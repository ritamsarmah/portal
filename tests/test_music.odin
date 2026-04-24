package main

import "core:math/cmplx"
import "core:testing"

TOLERANCE :: 1e-2

@(test)
test_bit_reverse_4bit :: proc(t: ^testing.T) {
	actual := bit_reverse(0b0011, 4)
	testing.expect_value(t, actual, 0b1100)
}

@(test)
test_bit_reverse_16bit :: proc(t: ^testing.T) {
	actual := bit_reverse(0b0110111011010001, 16)
	testing.expect_value(t, actual, 0b1000101101110110)
}

@(test)
test_bit_reverse_equal :: proc(t: ^testing.T) {
	actual := bit_reverse(0b10000001, 8)
	testing.expect_value(t, actual, 0b10000001)
}

@(test)
test_bit_reverse_permutation_small :: proc(t: ^testing.T) {
	data := [4]u32{1, 2, 3, 4}
	bit_reversal_permutation(data[:])

	testing.expect_value(t, data, [4]u32{1, 3, 2, 4})
}

@(test)
test_bit_reverse_permutation_large :: proc(t: ^testing.T) {
	data := [16]u32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	bit_reversal_permutation(data[:])

	testing.expect_value(t, data, [16]u32{1, 9, 5, 13, 3, 11, 7, 15, 2, 10, 6, 14, 4, 12, 8, 16})
}

@(test)
test_fft_length_1 :: proc(t: ^testing.T) {
	data := [1]complex64{1}
	fft(data[:])
	testing.expect_value(t, data, [1]complex64{1})
}

@(test)
test_fft_invalid_length :: proc(t: ^testing.T) {
	data := [5]complex64{1, 2, 3, 4, 5}
	testing.expect_assert(t, "Length must be a power of 2")
	fft(data[:])
}

// FFT test cases borrowed from https://lloydrochester.com/post/c/example-fft/

@(test)
test_fft_1 :: proc(t: ^testing.T) {
	data := [8]complex64{0 + 7i, 1 + 6i, 2 + 5i, 3 + 4i, 4 + 3i, 5 + 2i, 6 + 1i, 7 + 0i}
	expected := [8]complex64 {
		28.000 + 28.000i,
		5.656 + 13.656i,
		0.000 + 8.000i,
		-2.343 + 5.656i,
		-4.000 + 4.000i,
		-5.656 + 2.343i,
		-8.000 + 0.000i,
		-13.656 - 5.656i,
	}

	fft(data[:])

	if !complex_eq(data[:], expected[:], TOLERANCE) {
		testing.fail(t)
	}
}

@(test)
test_fft_2 :: proc(t: ^testing.T) {
	data := [8]complex64{1 + 1i, 1 + 1i, 1 + 1i, 1 + 1i, 1 + 1i, 1 + 1i, 1 + 1i, 1 + 1i}
	expected := [8]complex64{8 + 8i, 0 + 0i, 0 + 0i, 0 + 0i, 0 + 0i, 0 + 0i, 0 + 0i, -0 + 0i}

	fft(data[:])

	if !complex_eq(data[:], expected[:], TOLERANCE) {
		testing.fail(t)
	}
}

@(test)
test_fft_3 :: proc(t: ^testing.T) {
	data := [8]complex64{1 - 1i, -1 + 1i, 1 - 1i, -1 + 1i, 1 - 1i, -1 + 1i, 1 - 1i, -1 + 1i}
	expected := [8]complex64{0 + 0i, 0 + 0i, 0 + 0i, 0 + 0i, 8 - 8i, 0 + 0i, 0 + 0i, -0 + 0i}

	fft(data[:])

	if !complex_eq(data[:], expected[:], TOLERANCE) {
		testing.fail(t)
	}
}

@(test)
test_fft_4 :: proc(t: ^testing.T) {
	data := [4]complex64{1, 2, 3, 4}
	expected := [4]complex64{10, -2 + 2i, -2 + 0i, -2 - 2i}

	fft(data[:])

	if !complex_eq(data[:], expected[:], TOLERANCE) {
		testing.fail(t)
	}
}

complex_eq :: proc(a, b: []complex64, eps: f32) -> bool {
	if len(a) != len(b) do return false

	for i in 0 ..< len(a) {
		if cmplx.abs(a[i] - b[i]) > eps do return false
	}

	return true
}
