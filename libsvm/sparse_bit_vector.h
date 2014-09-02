/*
 ** Copyright 2014 Edward Walker
 **
 ** Licensed under the Apache License, Version 2.0 (the "License");
 ** you may not use this file except in compliance with the License.
 ** You may obtain a copy of the License at
 **
 ** http ://www.apache.org/licenses/LICENSE-2.0
 **
 ** Unless required by applicable law or agreed to in writing, software
 ** distributed under the License is distributed on an "AS IS" BASIS,
 ** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 ** See the License for the specific language governing permissions and
 ** limitations under the License.
 **
 ** Description: Experimental sparse bitvector support
 ** @author: Ed Walker
 */
#ifndef _SPARSE_BIT_VECTOR_H_
#define _SPARSE_BIT_VECTOR_H_
#include "svm_defs.h"
#include <iostream>
#include <stdint.h>

#define BITVECTOR_16BIT 0

#if BITVECTOR_16BIT
#define MAX_RUN			0x7FFF
#define BIT_SET			0x8000
#define BIT_MASK		0xFFFF
#define SHIFT_BITS		(2 * CHAR_BIT)
#define UINT32_SIZE		4 
typedef uint16_t blockType_t;
#else
#define MAX_RUN			0x7F
#define BIT_SET			0x80
#define BIT_MASK		0xFF
#define SHIFT_BITS		CHAR_BIT
#define UINT32_SIZE		4 
typedef uint8_t blockType_t;
#endif

class SparseBitVector {

	int pos; 		// last byte position filled
	int run_count; 	// the last index position that was set
	int cap; 		// capacity of bit vector in bytes
	uint8_t *bit;  	// the bit vector

	static const int memory_increment = 1000;

	void resize() {
		int new_cap = cap + sizeof(uint32_t) * memory_increment;
		uint8_t *new_bit = (uint8_t *)realloc(bit, new_cap);
		if (new_bit == NULL) {
			std::cerr << "sparse_bit_vector: realloc fail: " << new_cap << std::endl;
			throw std::runtime_error("fail to realloc bit vector");
		}
		bit = new_bit;
		cap = new_cap;
	}

	/**
 	* 	Initializes the next word at a 32-bit alignment boundary.
 	*/
	void init_word() {
		if ((pos % UINT32_SIZE) == 0) { // at a 32 bit alignment, we get to decide which mode we want to be in
			uint32_t *word = reinterpret_cast<uint32_t *>(&bit[pos]);
			*word = 0;
		}
	}

	/**
 	* 	Move to the next 32-bit word boundary
 	*/
	void align_pos() {
		int rem;
		if ((rem = pos % UINT32_SIZE) != 0) {
			pos += (UINT32_SIZE - rem);
			if (pos >= cap) {
				resize();
			}
		}
	}

	/**
 	* 	Sets the bit and the run length
 	*/
	template <typename T>
	void set_word_true(int len) {
		T *word = reinterpret_cast<T*>(&bit[pos]);
		*word |= (len | BIT_SET);
		pos += sizeof(T);
	}

	/**
 	* 	Sets the max run length and false bit
 	*/
	template <typename T>
	void set_word_false() {
		T *word = reinterpret_cast<T*>(&bit[pos]);
		*word |= MAX_RUN;
		pos += sizeof(T);
	}

	/**
 	* 	Sets the zero value sentinel
 	*/
	template <typename T>
	void set_word_sentinel() {
		pos += sizeof(T);
	}

	void set_buffer(int len, int idx)
	{
		do {
			init_word();
			if (len < 0) { // sentinel 	
				set_word_sentinel<blockType_t>();
				align_pos(); // move pos to the next 32-bit alignment
				run_count = 0; // reset run_count
			}
			else if (len > int(MAX_RUN)) {
				set_word_false<blockType_t>();
				len -= MAX_RUN;
			}
			else {
				set_word_true<blockType_t>(len);
				len = 0;
				run_count = idx;
			}

			if (pos >= cap) {
				resize();
			}

		} while (len > 0);
	}

public:
	static const int sentinel = -1;

	/**
 	* 	Set the initial bitvector size in 32-bit words
 	*/
	SparseBitVector(int size) :
		pos(0), cap(0), run_count(0),  bit(NULL) {

		if (size > 0) {
			cap = size * UINT32_SIZE;
			bit = (uint8_t *)malloc(cap);
			if (bit == NULL) {
				std::cerr << "SparseBitVector: fail to allocate " << cap << std::endl;
				throw std::runtime_error("fail to allocate bit vector");
			}
		}
	}

	~SparseBitVector () {
		if (bit) free(bit);
	}

	/**
 	* 	Sets position idx to "1"
 	*/
	void set(int idx) {
		int len = idx;

		if (idx >= 0 && idx < run_count) {
			std::cerr << "idx is too small: idx = " << idx << " current run count = " << run_count << std::endl;
			return;
		}
		len = idx - run_count; // number of "0" to this new "1" at idx
		
		set_buffer(len, idx);
	}


	/**
 	* 	Returns the sparse bit vector 
 	*/
	uint32_t *get_buffer(int &size) {
		align_pos();
		size = pos / UINT32_SIZE;
		return reinterpret_cast<uint32_t *>(bit);
	}

	/**
 	* 	Returns the current bit vector position 
 	**/
	int get_pos() {
		align_pos(); // move to next 32-bit boundary
		return pos / UINT32_SIZE; // return the last index position of the uint32_t array
	}

};
#endif
