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
** Description: Cuda device code and launchers
** @author: Ed Walker
*/

#include "svm.h"
#include <stdexcept>
#include <iostream>
using namespace std;
#include <stdio.h>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include "device_functions.h"
#include "math_constants.h"
#include "math.h"
#include "svm_device.h"
#include "cuda_reducer.h"
#include "svm_cache.h"
#include "sparse_bit_vector.h"

#define DEVICE_EPS	0

enum { LOWER_BOUND = 0, UPPER_BOUND = 1, FREE = 2 };

#if !USE_BITVECTOR_FORMAT
texture<float2, 1, cudaReadModeElementType> 	d_tex_space;
#else
texture<float1, 1, cudaReadModeElementType> 	d_tex_space;
#endif

#if USE_CONSTANT_INDEX
__constant__	int				*d_x;
#else
texture<int, 1, cudaReadModeElementType> 		d_tex_x;
#endif

#if USE_BITVECTOR_FORMAT
texture<uint32_t, 1, cudaReadModeElementType> 	d_tex_sparse_vector;
__device__ 		int				*d_bitvector_table;
__constant__	int				d_max_words;
#endif

__device__		int				d_kernel_type;	// enum { LINEAR, POLY, RBF, SIGMOID, PRECOMPUTED }; /* kernel_type */
__device__		int				d_svm_type;		// enum { C_SVC, NU_SVC, ONE_CLASS, EPSILON_SVR, NU_SVR };	/* svm_type */
__constant__	double			d_gamma;		// rbf, poly, and sigmoid kernel
__constant__	double			d_coef0;		// poly and sigmoid kernel
__constant__	int				d_degree;		// poly kernel
__constant__	int				d_l;			// original # SV

__constant__	CValue_t		*d_x_square;
__constant__	CValue_t		*d_QD;
__constant__	SChar_t			*d_y;
__constant__	double			d_Cp;
__constant__	double			d_Cn;

__device__		GradValue_t		*d_G;
__device__		GradValue_t		*d_alpha;
__device__		char			*d_alpha_status;

__device__		GradValue_t		d_delta_alpha_i;
__device__		GradValue_t		d_delta_alpha_j;

__device__		int2			d_solver; // member x and y hold the selected i and j working set indices respectively
__device__		int2			d_nu_solver; // member x and y hold the Gmaxp_idx and Gmaxn_idx indices respectively.  

cudaError_t update_sparse_vector(uint32_t *dh_sparse_vector, int sparse_vector_size, int *dh_bitvector_table, int bitvector_table_size, int max_words)
{
	cudaError_t err = cudaSuccess;

#if USE_BITVECTOR_FORMAT
	if (dh_sparse_vector != NULL) {
		err = cudaBindTexture(NULL, d_tex_sparse_vector, dh_sparse_vector, sparse_vector_size);
		if (err != cudaSuccess) {
			fprintf(stderr, "Error binding to texture d_tex_sparse_vector\n");
			return err;
		}
	}

#if USE_SPARSE_BITVECTOR_FORMAT
	if (dh_bitvector_table == NULL) {
		fprintf(stderr, "Error: dh_bitvector_table cannot be NULL\n");
		return cudaErrorInvalidConfiguration;
	}
	err = cudaMemcpyToSymbol(d_bitvector_table, &dh_bitvector_table, sizeof(dh_bitvector_table));
	if (err != cudaSuccess) {
		fprintf(stderr, "Error copying symbol to d_bitvector_table\n");
		return err;
	}

#endif

	if (max_words > 0) {
		err = cudaMemcpyToSymbol(d_max_words, &max_words, sizeof(max_words));
		if (err != cudaSuccess) {
			fprintf(stderr, "Error copying to symbol d_max_words\n");
			return err;
		}
	}
#endif
	return err;
}

cudaError_t update_param_constants(const svm_parameter &param, int *dh_x, cuda_svm_node *dh_space, size_t dh_space_size, int l)
{
	cudaError_t err;
	err = cudaMemcpyToSymbol(d_l, &l, sizeof(l));
	if (err != cudaSuccess) {
		fprintf(stderr, "Error with copying to symbol d_l\n");
		return err;
	}
	err = cudaMemcpyToSymbol(d_kernel_type, &param.kernel_type, sizeof(param.kernel_type));
	if (err != cudaSuccess) {
		fprintf(stderr, "Error with copying to symbol d_kernel_type\n");
		return err;
	}
	err = cudaMemcpyToSymbol(d_svm_type, &param.svm_type, sizeof(param.svm_type));
	if (err != cudaSuccess) {
		fprintf(stderr, "Error with copying to symbol d_svm_type\n");
		return err;
	}
	err = cudaMemcpyToSymbol(d_gamma, &param.gamma, sizeof(param.gamma));
	if (err != cudaSuccess) {
		fprintf(stderr, "Error with copying to symbol d_gamma\n");
		return err;
	}
	err = cudaMemcpyToSymbol(d_coef0, &param.coef0, sizeof(param.coef0));
	if (err != cudaSuccess) {
		fprintf(stderr, "Error with copying to symbol d_coef0\n");
		return err;
	}
	err = cudaMemcpyToSymbol(d_degree, &param.degree, sizeof(param.degree));
	if (err != cudaSuccess) {
		fprintf(stderr, "Error with copying to symbol d_degree\n");
		return err;
	}

#if USE_CONSTANT_INDEX
	err = cudaMemcpyToSymbol(d_x, &dh_x, sizeof(dh_x));
	if (err != cudaSuccess) {
		fprintf(stderr, "Error copying to symbol d_x\n");
		return err;
	}
#else
	err = cudaBindTexture(0, d_tex_x, dh_x, l*sizeof(int));
	if (err != cudaSuccess) {
		fprintf(stderr, "Error binding to d_tex_space\n");
		return err;
	}
#endif

	err = cudaBindTexture(0, d_tex_space, dh_space, dh_space_size);
	if (err != cudaSuccess) {
		fprintf(stderr, "Error binding to d_tex_space\n");
		return err;
	}

	return err;
}

cudaError_t update_solver_variables(SChar_t *dh_y, CValue_t *dh_QD, GradValue_t *dh_G, GradValue_t *dh_alpha, char *dh_alpha_status, double Cp, double Cn)
{
	cudaError_t err;

	err = cudaMemcpyToSymbol(d_y, &dh_y, sizeof(dh_y));
	if (err != cudaSuccess) {
		fprintf(stderr, "Error copying to symbol d_y\n");
		return err;
	}
	err = cudaMemcpyToSymbol(d_QD, &dh_QD, sizeof(dh_QD));
	if (err != cudaSuccess) {
		fprintf(stderr, "Error copying to symbol d_QD\n");
		return err;
	}
	err = cudaMemcpyToSymbol(d_G, &dh_G, sizeof(dh_G));
	if (err != cudaSuccess) {
		fprintf(stderr, "Error copying to symbol d_G\n");
		return err;
	}
	err = cudaMemcpyToSymbol(d_alpha, &dh_alpha, sizeof(dh_alpha));
	if (err != cudaSuccess) {
		fprintf(stderr, "Error copying to symbol d_alpha\n");
		return err;
	}
	err = cudaMemcpyToSymbol(d_alpha_status, &dh_alpha_status, sizeof(dh_alpha_status));
	if (err != cudaSuccess) {
		fprintf(stderr, "Error copying to symbol d_alpha_status\n");
		return err;
	}

	err = cudaMemcpyToSymbol(d_Cp, &Cp, sizeof(Cp));
	if (err != cudaSuccess) {
		fprintf(stderr, "Error with copying to symbol d_Cp\n");
		return err;
	}
	err = cudaMemcpyToSymbol(d_Cn, &Cn, sizeof(Cn));
	if (err != cudaSuccess) {
		fprintf(stderr, "Error with copying to symbol d_Cn\n");
		return err;
	}
	return err;
}

cudaError_t update_rbf_variables(CValue_t *dh_x_square)
{
	cudaError_t err;
	if (dh_x_square != NULL) {
		err = cudaMemcpyToSymbol(d_x_square, &dh_x_square, sizeof(dh_x_square));
		if (err != cudaSuccess) {
			fprintf(stderr, "Error copying to symbol d_x_square\n");
			return err;
		}
	}
	return err;
}

void unbind_texture()
{
	cudaUnbindTexture(d_tex_space);

#if USE_BITVECTOR_FORMAT
	cudaUnbindTexture(d_tex_sparse_vector);
#endif

#if !USE_CONSTANT_INDEX
	cudaUnbindTexture(d_tex_x);
#endif
}

__device__ __forceinline__ 
cuda_svm_node get_col_value(int i)
{
	return tex1Dfetch(d_tex_space, i);
}

__device__ __forceinline__ 
int get_x(int i)
{
#if USE_CONSTANT_INDEX
	return d_x[i];
#else
	return tex1Dfetch(d_tex_x, i);
#endif
}

#if !USE_BITVECTOR_FORMAT
/**
Compute dot product of 2 vectors
*/
__device__ 
CValue_t dot(int i, int j)
{
	int i_col = get_x(i);
	int j_col = get_x(j);
	/**
	remember: 
	cuda_svm_node.y == svm_node.index
	cuda_svm_node.x == svm_node.value
	*/
	cuda_svm_node x = get_col_value(i_col);
	cuda_svm_node y = get_col_value(j_col);

	double sum = 0;
	while (x.y != -1 && y.y != -1)
	{
		if (x.y == y.y)
		{
			sum += x.x * y.x;
			x = get_col_value(++i_col);
			y = get_col_value(++j_col);
		}
		else
		{
			if (x.y > y.y) {
				y = get_col_value(++j_col);
			}
			else {
				x = get_col_value(++i_col);
			}
		}
	}
	return sum;
}
#else

__device__ __forceinline__ 
uint32_t get_bitvector(int i)
{
	return tex1Dfetch(d_tex_sparse_vector, i);
}

#if USE_SPARSE_BITVECTOR_FORMAT
__device__ __forceinline__
int get_bitvector_table(int i)
{
	return d_bitvector_table[i];
}

__device__ __forceinline__
int get_next_idx(int idx, size_t &run, uint32_t &pattern, int &poffset)
{
#if BITVECTOR_16BIT
	size_t sizeof_run = 2;
#else
	size_t sizeof_run = 4;
#endif
	if ((pattern & BIT_MASK) == 0)
		return -1;

	bool done;
	do {
		idx += (pattern & MAX_RUN);
		done = (pattern & BIT_SET);
		pattern >>= SHIFT_BITS;
		++run;
		if (run == sizeof_run) {
			pattern = get_bitvector(poffset++);
			run = 0;
		}
	} while (!done);
	return idx;
}

/**
  Compute dot product of 2 vectors
  */
__device__ 
CValue_t dot(int i, int j)
{
	int i_off = get_x(i);
	int j_off = get_x(j);

	int i_poffset = get_bitvector_table(i);
	int j_poffset = get_bitvector_table(j);

	uint32_t i_pattern, j_pattern;
	int i_idx = 0, j_idx = 0;
	size_t i_run = 0, j_run = 0;

	i_pattern = get_bitvector(i_poffset++); // fetch the index mask for i
	i_idx = get_next_idx(i_idx, i_run, i_pattern, i_poffset);

	j_pattern = get_bitvector(j_poffset++); // fetch the index mask for j
	j_idx = get_next_idx(j_idx, j_run, j_pattern, j_poffset);

	CValue_t sum = 0;
	while (i_idx != -1 && j_idx != -1) {
		if (i_idx == j_idx) {
			cuda_svm_node x = get_col_value(i_off++);
			cuda_svm_node y = get_col_value(j_off++);
			sum += x.x * y.x;
			i_idx = get_next_idx(i_idx, i_run, i_pattern, i_poffset);
			j_idx = get_next_idx(j_idx, j_run, j_pattern, j_poffset);
		}
		else if (i_idx < j_idx) {
			i_off++;
			i_idx = get_next_idx(i_idx, i_run, i_pattern, i_poffset);
		}
		else {
			j_off++;
			j_idx = get_next_idx(j_idx, j_run, j_pattern, j_poffset);
		}
	}
	return sum;
}

#else
__device__ __forceinline__ 
uint32_t least_significant_bit(uint32_t x, uint32_t &x_nobit)
{
	x_nobit = x & (x - 1);
	return x & ~x_nobit;
}

/**
  Compute dot product of 2 vectors
  */
__device__ 
CValue_t dot(int i, int j)
{
	int i_off = get_x(i);
	int j_off = get_x(j);
	size_t i_poffset = i * d_max_words;
	size_t j_poffset = j * d_max_words;
	/**
		remember:
		cuda_svm_node.x == svm_node.value
	*/
	uint32_t x_pattern, y_pattern;
	CValue_t sum = 0;
	for (int k1 = 0; k1 < d_max_words; k1++) {
		x_pattern = get_bitvector(i_poffset++); // fetch the index mask for i
		y_pattern = get_bitvector(j_poffset++); // fetch the index mask for j

		if (x_pattern == 0 && y_pattern == 0)
			continue;

		uint32_t bx = 0, by = 0;
		uint32_t xbit = 0, ybit = 0;

		if (x_pattern > 0) {
			xbit = least_significant_bit(x_pattern, bx); // get the first least significant bit in x
		}
		if (y_pattern > 0) {
			ybit = least_significant_bit(y_pattern, by); // get the first least significant bit in y
		}

		do {
			bool move_x = false, move_y = false;
			if (xbit == ybit) { // both bits are in the same position
				// index matches! hence we multiply
				cuda_svm_node x = get_col_value(i_off);
				cuda_svm_node y = get_col_value(j_off);
				sum += x.x * y.x;

				move_x = true;
				move_y = true;
			}
			else if (y_pattern == 0) {
				move_x = true;
			}
			else if (x_pattern == 0) {
				move_y = true;
			}
			else if (ybit < xbit) {
				move_y = true;
			}
			else if (xbit < ybit) {
				move_x = true;
			}

			if (move_x) {
				i_off++;
				x_pattern = bx;
				xbit = least_significant_bit(x_pattern, bx); // move to the next bit in x
			}
			if (move_y) {
				j_off++;
				y_pattern = by;
				ybit = least_significant_bit(y_pattern, by); // move to the next bit in y
			}
		} while (x_pattern > 0 || y_pattern > 0);
	}
	return sum;
}
#endif
#endif

__device__ 
CValue_t device_kernel_rbf(const int &i, const int &j)
{
	CValue_t q = d_x_square[i] + d_x_square[j] - 2 * dot(i, j);
	return exp(-(CValue_t)d_gamma * q);
}

__device__ 
CValue_t device_kernel_poly(const int &i, const int &j)
{
	return pow((CValue_t)d_gamma * dot(i, j) + (CValue_t)d_coef0, d_degree);
}

__device__ 
CValue_t device_kernel_sigmoid(const int &i, const int &j)
{
	return tanh((CValue_t)d_gamma * dot(i, j) + (CValue_t)d_coef0);
}

__device__ 
CValue_t device_kernel_linear(const int &i, const int &j)
{
	return dot(i, j);
}

__device__ 
CValue_t device_kernel_precomputed(const int &i, const int &j)
{
	int i_col = get_x(i);
	int j_col = get_x(j);
	int offset = static_cast<int>(get_col_value(j_col).x);
	return get_col_value(i_col + offset).x;
	// return x[i][(int)(x[j][0].value)].value;
}

/**
Returns the product of the kernel function multiplied with rc
@param i	index i
@param j	index j
@param rc	multiplier for the kernel function
*/
__device__ __forceinline__ 
CValue_t kernel(const int &i, const int &j, const CValue_t &rc)
{
	switch (d_kernel_type)
	{
	case RBF:
		return rc * device_kernel_rbf(i, j);
	case POLY:
		return rc * device_kernel_poly(i, j);
	case LINEAR:
		return rc * device_kernel_linear(i, j);
	case SIGMOID:
		return rc * device_kernel_sigmoid(i, j);
	case PRECOMPUTED:
		return rc * device_kernel_precomputed(i, j);
	}

	return 0;
}

/**
	Implements schar *SVR_Q::sign
	[0..l-1] --> 1
	[l..2*l) --> -1
*/
__device__ __forceinline__ 
SChar_t device_SVR_sign(int i)
{
	return (i < d_l ? 1 : -1);
}

/**
	Implements int *SVR_Q::index
	[0..l-1] --> [0..l-1]
	[l..2*l) --> [0..1-1]
*/
__device__ __forceinline__ 
int device_SVR_real_index(int i)
{
	return (i < d_l ? i : (i - d_l));
}

__device__ 
CValue_t cuda_evalQ(int i, int j)
{
	CValue_t rc = 1;

	switch (d_svm_type)
	{
	case C_SVC:
	case NU_SVC:
		// SVC_Q
		rc = (CValue_t)(d_y[i] * d_y[j]);
		break;
	case ONE_CLASS:
		// ONE_CLASS_Q - nothing to do
		break;
	case EPSILON_SVR:
	case NU_SVR:
		// SVR_Q
		rc = (CValue_t)(device_SVR_sign(i) * device_SVR_sign(j));
		i = device_SVR_real_index(i); // use the kernel calculation
		j = device_SVR_real_index(j); // use for kernel calculation
		break;
	}

	return kernel(i, j, rc);
}

__global__ 
void cuda_find_min_idx(CValue_t *obj_diff_array, int *obj_diff_indx, CValue_t *result_obj_min, int *result_indx, int N)
{
	D_MinIdxReducer func(obj_diff_array, obj_diff_indx, result_obj_min, result_indx); // Class defined in CudaReducer.h
	device_block_reducer(func, N); // Template function defined in CudaReducer.h
	if (blockIdx.x == 0)
		d_solver.y = func.return_idx();
}

__device__ 
void device_compute_obj_diff(int i, int j, CValue_t Qij, GradValue_t Gmax, CValue_t *dh_obj_diff_array, int *result_indx)
{

	dh_obj_diff_array[j] = CVALUE_MAX;
	result_indx[j] = -1;
	if (d_y[j] == 1)
	{
		if (!(d_alpha_status[j] == LOWER_BOUND)/*is_lower_bound(j)*/)
		{
			GradValue_t grad_diff = Gmax + d_G[j];
			if (grad_diff > DEVICE_EPS) // original: grad_diff > 0
			{
				CValue_t quad_coef = d_QD[i] + d_QD[j] - 2.0 * d_y[i] * Qij;
				CValue_t obj_diff = CVALUE_MAX;

				if (quad_coef > 0) {
					obj_diff = -(grad_diff*grad_diff) / quad_coef;
				}
				else {
					obj_diff = -(grad_diff*grad_diff) / TAU;
				}
				CHECK_FLT_RANGE(obj_diff);
				CHECK_FLT_INF(obj_diff);
				dh_obj_diff_array[j] = obj_diff;
				result_indx[j] = j;
			}

		}
	}
	else
	{
		if (!(d_alpha_status[j] == UPPER_BOUND) /*is_upper_bound(j)*/)
		{
			GradValue_t grad_diff = Gmax - d_G[j];
			if (grad_diff > DEVICE_EPS) // original: grad_diff > 0
			{
				CValue_t quad_coef = d_QD[i] + d_QD[j] + 2.0 * d_y[i] * Qij;
				CValue_t obj_diff = CVALUE_MAX;

				if (quad_coef > 0) {
					obj_diff = -(grad_diff*grad_diff) / quad_coef;
				}
				else {
					obj_diff = -(grad_diff*grad_diff) / TAU;
				}
				CHECK_FLT_RANGE(obj_diff);
				CHECK_FLT_INF(obj_diff);
				dh_obj_diff_array[j] = obj_diff;
				result_indx[j] = j;
			}
		}
	}

}

__global__ 
void cuda_compute_obj_diff(GradValue_t Gmax, CValue_t *dh_obj_diff_array, int *result_indx, int N)
{
	int i = d_solver.x;

	for (int j = blockDim.x * blockIdx.x + threadIdx.x;
		j < N;
		j += blockDim.x * gridDim.x) {	

		CValue_t Qij;
		bool valid;
		CValue_t *Qi = cache_get_Q(i, valid, STAGE_AREA_I); // staged for later use and update
		if (valid) { // reuse what we already have
			Qij = Qi[j];
		}
		else {
			Qij = cuda_evalQ(i, j);
			Qi[j] = Qij;
		}

		device_compute_obj_diff(i, j, Qij, Gmax, dh_obj_diff_array, result_indx);
	}
}

__global__ 
void cuda_compute_obj_diff_SVR(GradValue_t Gmax, CValue_t *dh_obj_diff_array, int *result_indx, int N)
{
	int i = d_solver.x;

	for (int j = blockDim.x * blockIdx.x + threadIdx.x;
		j < N;
		j += blockDim.x * gridDim.x) {

		CValue_t Qij1, Qij2;
		bool valid;
		CValue_t *Qi = cache_get_Q(i, valid, STAGE_AREA_I); // staged for later use and update
		if (valid) { // reuse what we already have
			Qij1 = Qi[j];
			Qij2 = Qi[j + d_l];
		}
		else {
			Qij1 = cuda_evalQ(i, j);
			Qi[j] = Qij1;

			Qij2 = -Qij1;
			Qi[j + d_l] = Qij2;
		}

		device_compute_obj_diff(i, j, Qij1, Gmax, dh_obj_diff_array, result_indx);
		device_compute_obj_diff(i, j + d_l, Qij2, Gmax, dh_obj_diff_array, result_indx);
	}
}

__global__ 
void cuda_update_gradient(int N)
{
	int i = d_solver.x; // selected i index
	int j = d_solver.y; // selected j index

	for (int k = blockIdx.x * blockDim.x + threadIdx.x; 
		k < N;
		k += blockDim.x * gridDim.x) {

		CValue_t *Qi, *Qj;
		CValue_t Qik, Qjk;

		Qi = cache_get_Stage(i, STAGE_AREA_I);
		if (Qi) {
			Qik = Qi[k];
		}
		else {
			Qik = cuda_evalQ(i, k);
		}

		bool valid;
		Qj = cache_get_Q(j, valid, STAGE_AREA_J);
		if (valid) {
			Qjk = Qj[k];
		}
		else {
			Qjk = cuda_evalQ(j, k);
			Qj[k] = Qjk;
		}

		d_G[k] += (Qik* d_delta_alpha_i + Qjk * d_delta_alpha_j);
	}
}

__global__ 
void cuda_update_gradient_SVR(int N)
{
	int i = d_solver.x; // selected i index
	int j = d_solver.y; // selected j index

	for (int k = blockIdx.x * blockDim.x + threadIdx.x; 
		k < N;
		k += blockDim.x * gridDim.x) {

		CValue_t *Qi, *Qj;
		CValue_t Qik1, Qik2, Qjk1, Qjk2;

		Qi = cache_get_Stage(i, STAGE_AREA_I);
		if (Qi) {
			Qik1 = Qi[k];
			Qik2 = Qi[k + d_l];
		} else {
			Qik1 = cuda_evalQ(i, k);
			Qik2 = cuda_evalQ(i, k + d_l);
		}

		bool valid;
		Qj = cache_get_Q(j, valid, STAGE_AREA_J);
		if (valid) {
			Qjk1 = Qj[k];
			Qjk2 = Qj[k + d_l];
		}
		else {
			Qjk1 = cuda_evalQ(j, k);
			Qj[k] = Qjk1;

			Qjk2 = -Qjk1;
			Qj[k + d_l] = Qjk2;
		}

		d_G[k] += (Qik1 * d_delta_alpha_i + Qjk1 * d_delta_alpha_j);
		d_G[k + d_l] += (Qik2 * d_delta_alpha_i + Qjk2 * d_delta_alpha_j);
	}
}

__global__ 
void cuda_init_gradient(int start, int step, int N)
{
	int j = blockIdx.x * blockDim.x + threadIdx.x;
	if (j >= N)
		return;

	GradValue_t acc = 0;
	for (int i = start; i < N && i < start + step; ++i)
	{
		if (!(d_alpha_status[i] == LOWER_BOUND) /*is_lower_bound(i)*/)
		{
			acc += d_alpha[i] * cuda_evalQ(i, j);
		}
	}

	d_G[j] += acc;
}

#if USE_DOUBLE_GRADIENT // needed if we are storing double gradient values
/**
double version of atomicAdd
*/
__device__ 
double atomicAdd(double * address, double val)
{
	unsigned long long int *address_as_ull =
		(unsigned long long int*)address;
	unsigned long long int old = *address_as_ull, assumed;
	do {
		assumed = old;
		old = atomicCAS(address_as_ull, assumed,
			__double_as_longlong(val + __longlong_as_double(assumed)));
	} while (assumed != old);
	return __longlong_as_double(old);
}
#endif

__device__ 
GradValue_t device_compute_gradient(int i, int j)
{
	if (!(d_alpha_status[i] == LOWER_BOUND)) /* !is_lower_bound(i) */
	{
		return d_alpha[i] * cuda_evalQ(i, j);
	}
	else
		return 0;
}


__device__ __forceinline__ 
GradValue_t warpReduceSum(GradValue_t val) 
{
#if __CUDA_ARCH__ >= 300
	for (int offset = warpSize/2; offset > 0; offset /= 2) {
		val += __shfl_down(val, offset);
	}
#endif
	return val;
}

__device__ __forceinline__ 
GradValue_t blockReduceSum(GradValue_t val) 
{
#if __CUDA_ARCH__ >= 300
	static __shared__ GradValue_t shared[32]; // Shared mem for 32 partial sums
	int lane = threadIdx.x % warpSize;
	int wid = threadIdx.x / warpSize;

	val = warpReduceSum(val);     // Each warp performs partial reduction

	if (lane==0) shared[wid]=val;	// Write reduced value to shared memory

	__syncthreads();              // Wait for all partial reductions

	//read from shared memory only if that warp existed
	val = (threadIdx.x < blockDim.x / warpSize) ? shared[lane] : 0;

	if (wid==0) val = warpReduceSum(val); //Final reduce within first warp
#endif
	return val;
}

__global__ 
void cuda_init_gradient_block2(int startj, int N)
{
	int j = blockIdx.y * blockDim.y + threadIdx.y + startj;
	if (j >= N)
		return ;

	GradValue_t sum = 0;
	for (int i = blockIdx.x * blockDim.x + threadIdx.x;
			i < N;
			i += blockDim.x * gridDim.x) {
		sum += device_compute_gradient(i, j);
	}

#if BLOCK_ATOMIC_REDUCE
	sum = blockReduceSum(sum);

	if (threadIdx.x == 0) { 
		atomicAdd(&d_G[j], sum);
	}
#else
	sum = warpReduceSum(sum);

	if (threadIdx.x & (warpSize - 1) == 0) { 
		atomicAdd(&d_G[j], sum);
	}
#endif

	return;
}

__global__ 
void cuda_init_gradient_block1(int startj, int N)
{
	int i = blockIdx.x * blockDim.x * 2 + threadIdx.x;
	int j = blockIdx.y * blockDim.y + threadIdx.y + startj;

	if (j >= N || i >= N)
		return;

	D_GradientAdder func(j, N);
	device_block_reducer(func, N);

	if (threadIdx.x == 0) { // every block in the x-axis (ie. i)
		GradValue_t s = func.return_sum();
		atomicAdd(&d_G[j], s);
	}

	return;
}

/**
	Initializes the gradient vector on the device
	@param block_size	number of threads per block
	@param startj		starting index j for G_j
	@param stepj		number of steps from startj to update
	@param N			size of gradient vector
*/
void init_device_gradient2(int block_size, int startj, int stepj, int N)
{
	dim3 grid;
	// the number of blocks in the ith dimension
	grid.x = std::min((N + block_size-1) / block_size, 1024);
	// the number of blocks in the jth dimension == G_j that will be updated
	grid.y = stepj; 

	dim3 block;
	block.x = block_size; // number of threads in the ith dimension
	block.y = 1; // number of threads per block in the jth dimension (one thread per block)
	cuda_init_gradient_block2 << <grid, block >> > (startj, N);
	check_cuda_kernel_launch("fail in cuda_init_gradient_block2");
}

/**
	Initializes the gradient vector on the device
	@param block_size	number of threads per block
	@param startj		starting index j for G_j
	@param stepj		number of steps from startj to update
	@param N			size of gradient vector
*/
void init_device_gradient1(int block_size, int startj, int stepj, int N)
{
	int reduce_block_size = 2 * block_size;
	dim3 grid;
	// the number of blocks in the ith dimension
	grid.x = (N+reduce_block_size-1) / reduce_block_size;
	// the number of blocks in the jth dimension == G_j that will be updated
	grid.y = stepj; 

	dim3 block;
	block.x = block_size; // number of threads in the ith dimension
	block.y = 1; // number of threads per block in the jth dimension (one thread per block)
	
	size_t shared_mem = block.x * sizeof(GradValue_t);
	cuda_init_gradient_block1 << <grid, block, shared_mem >> > (startj, N);
	check_cuda_kernel_launch("fail in cuda_init_gradient_block1");
}

__global__ 
void cuda_find_gmax(find_gmax_param param, int N, bool debug)
{
	D_GmaxReducer func(param.dh_gmax, param.dh_gmax2, param.dh_gmax_idx, param.result_gmax, 
		param.result_gmax2, param.result_gmax_idx, debug); // class defined in CudaReducer.h

	device_block_reducer(func, N); // Template function defined in CudaReducer.h

	if (blockIdx.x == 0 && threadIdx.x == 0)
		d_solver.x = func.return_idx();
}

__global__ 
void cuda_setup_x_square(int N)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i >= N)
		return;
	d_x_square[i] = dot(i, i);
}

__global__ 
void cuda_setup_QD(int N)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i >= N)
		return;

	d_QD[i] = kernel(i, i, 1);

	if (d_svm_type == NU_SVR || d_svm_type == EPSILON_SVR)
		d_QD[i + d_l] = d_QD[i];
}

__global__ 
void cuda_prep_gmax(GradValue_t *dh_gmax, GradValue_t *dh_gmax2, int *dh_gmax_idx, int N)
{
	int t = blockIdx.x * blockDim.x + threadIdx.x;

	if (t >= N)
		return;

	dh_gmax[t] = -GRADVALUE_MAX;
	dh_gmax2[t] = -GRADVALUE_MAX;
	dh_gmax_idx[t] = -1;
	if (d_y[t] == +1)
	{
		if (!(d_alpha_status[t] == UPPER_BOUND) /*is_upper_bound(t)*/) {
			dh_gmax[t] = -d_G[t];
			dh_gmax_idx[t] = t;
		}
		if (!(d_alpha_status[t] == LOWER_BOUND) /*is_lower_bound(t)*/) {
			dh_gmax2[t] = d_G[t];
		}
	}
	else
	{
		if (!(d_alpha_status[t] == LOWER_BOUND) /*is_lower_bound(t)*/) {
			dh_gmax[t] = d_G[t];
			dh_gmax_idx[t] = t;
		}
		if (!(d_alpha_status[t] == UPPER_BOUND) /*is_upper_bound(t)*/) {
			dh_gmax2[t] = -d_G[t];
		}
	}
}

__device__	__forceinline__ 
double device_get_C(int i)
{
	return (d_y[i] > 0) ? d_Cp : d_Cn;
}

__global__ 
void cuda_compute_alpha()
{
	int i = d_solver.x; // d_selected_i;
	int j = d_solver.y; // d_selected_j;

	GradValue_t C_i = device_get_C(i);
	GradValue_t C_j = device_get_C(j);

	GradValue_t old_alpha_i = d_alpha[i];
	GradValue_t old_alpha_j = d_alpha[j];

	if (d_y[i] != d_y[j])
	{
		GradValue_t quad_coef = d_QD[i] + d_QD[j] + 2 * cuda_evalQ(i, j); //  Q_i[j];
		if (quad_coef <= 0)
			quad_coef = TAU;
		GradValue_t delta = (-d_G[i] - d_G[j]) / quad_coef;
		GradValue_t diff = d_alpha[i] - d_alpha[j];
		d_alpha[i] += delta;
		d_alpha[j] += delta;

		if (diff > 0)
		{
			if (d_alpha[j] < 0)
			{
				d_alpha[j] = 0;
				d_alpha[i] = diff;
			}
		}
		else
		{
			if (d_alpha[i] < 0)
			{
				d_alpha[i] = 0;
				d_alpha[j] = -diff;
			}
		}
		if (diff > C_i - C_j)
		{
			if (d_alpha[i] > C_i)
			{
				d_alpha[i] = C_i;
				d_alpha[j] = C_i - diff;
			}
		}
		else
		{
			if (d_alpha[j] > C_j)
			{
				d_alpha[j] = C_j;
				d_alpha[i] = C_j + diff;
			}
		}
	}
	else
	{
		GradValue_t quad_coef = d_QD[i] + d_QD[j] - 2 * cuda_evalQ(i, j); // Q_i[j];
		if (quad_coef <= 0)
			quad_coef = TAU;
		GradValue_t delta = (d_G[i] - d_G[j]) / quad_coef;
		GradValue_t sum = d_alpha[i] + d_alpha[j];
		d_alpha[i] -= delta;
		d_alpha[j] += delta;

		if (sum > C_i)
		{
			if (d_alpha[i] > C_i)
			{
				d_alpha[i] = C_i;
				d_alpha[j] = sum - C_i;
			}
		}
		else
		{
			if (d_alpha[j] < 0)
			{
				d_alpha[j] = 0;
				d_alpha[i] = sum;
			}
		}
		if (sum > C_j)
		{
			if (d_alpha[j] > C_j)
			{
				d_alpha[j] = C_j;
				d_alpha[i] = sum - C_j;
			}
		}
		else
		{
			if (d_alpha[i] < 0)
			{
				d_alpha[i] = 0;
				d_alpha[j] = sum;
			}
		}
	}
	d_delta_alpha_i = d_alpha[i] - old_alpha_i;
	d_delta_alpha_j = d_alpha[j] - old_alpha_j;
}

__device__ 
void device_update_alpha_status(int i)
{
	if (d_alpha[i] >= device_get_C(i))
		d_alpha_status[i] = UPPER_BOUND;
	else if (d_alpha[i] <= 0)
		d_alpha_status[i] = LOWER_BOUND;
	else
		d_alpha_status[i] = FREE;
}

__global__ 
void cuda_update_alpha_status()
{
	int i = d_solver.x;
	int j = d_solver.y;

	device_update_alpha_status(i);
	device_update_alpha_status(j);

	cache_commit_Stages(i, j);
}

/*********** NU Solver ************/


__global__ 
void cuda_prep_nu_gmax(GradValue_t *dh_gmaxp, GradValue_t *dh_gmaxn, GradValue_t *dh_gmaxp2, GradValue_t *dh_gmaxn2,
	int *dh_gmaxp_idx, int *dh_gmaxn_idx, int N)
{
	int t = blockIdx.x * blockDim.x + threadIdx.x;

	if (t >= N)
		return;

	dh_gmaxp[t] = -GRADVALUE_MAX;
	dh_gmaxp2[t] = -GRADVALUE_MAX;
	dh_gmaxn[t] = -GRADVALUE_MAX;
	dh_gmaxn2[t] = -GRADVALUE_MAX;
	dh_gmaxp_idx[t] = -1;
	dh_gmaxn_idx[t] = -1;

	if (d_y[t] == +1)
	{
		if (!(d_alpha_status[t] == UPPER_BOUND) /*is_upper_bound(t)*/) {
			dh_gmaxp[t] = -d_G[t];
			dh_gmaxp_idx[t] = t;
		}
		if (!(d_alpha_status[t] == LOWER_BOUND) /*is_lower_bound(t)*/) {
			dh_gmaxp2[t] = d_G[t];
		}
	}
	else
	{
		if (!(d_alpha_status[t] == LOWER_BOUND) /*is_lower_bound(t)*/) {
			dh_gmaxn[t] = d_G[t];
			dh_gmaxn_idx[t] = t;
		}
		if (!(d_alpha_status[t] == UPPER_BOUND) /*is_upper_bound(t)*/) {
			dh_gmaxn2[t] = -d_G[t];
		}
	}
}

__device__ 
void device_compute_nu_obj_diff(int ip, int in, int j, CValue_t Qipj, GradValue_t Gmaxp, GradValue_t Gmaxn, CValue_t *dh_obj_diff_array, int *result_idx)
{

	dh_obj_diff_array[j] = CVALUE_MAX;
	result_idx[j] = -1;
	if (d_y[j] == 1)
	{
		if (!(d_alpha_status[j] == LOWER_BOUND)/*is_lower_bound(j)*/)
		{
			GradValue_t grad_diff = Gmaxp + d_G[j];
			if (grad_diff > DEVICE_EPS) // original: grad_diff > 0
			{
				CValue_t quad_coef = d_QD[ip] + d_QD[j] - 2.0 * Qipj;
				CValue_t obj_diff = CVALUE_MAX;

				if (quad_coef > 0) {
					obj_diff = -(grad_diff*grad_diff) / quad_coef;
				}
				else {
					obj_diff = -(grad_diff*grad_diff) / TAU;
				}
				CHECK_FLT_RANGE(obj_diff);
				CHECK_FLT_INF(obj_diff);
				dh_obj_diff_array[j] = obj_diff;
				result_idx[j] = j;
			}

		}
	}
	else
	{
		if (!(d_alpha_status[j] == UPPER_BOUND) /*is_upper_bound(j)*/)
		{
			GradValue_t grad_diff = Gmaxn - d_G[j];
			if (grad_diff > DEVICE_EPS) // original: grad_diff > 0
			{
				CValue_t quad_coef = d_QD[in] + d_QD[j] - 2.0 * cuda_evalQ(in, j);
				CValue_t obj_diff = CVALUE_MAX;

				if (quad_coef > 0) {
					obj_diff = -(grad_diff*grad_diff) / quad_coef;
				}
				else {
					obj_diff = -(grad_diff*grad_diff) / TAU;
				}
				CHECK_FLT_RANGE(obj_diff);
				CHECK_FLT_INF(obj_diff);
				dh_obj_diff_array[j] = obj_diff;
				result_idx[j] = j;
			}
		}
	}

}

__global__ 
void cuda_compute_nu_obj_diff(GradValue_t Gmaxp, GradValue_t Gmaxn, CValue_t *dh_obj_diff_array, int *result_idx, int N)
{
	int ip = d_nu_solver.x;
	int in = d_nu_solver.y;

	for (int j = blockDim.x * blockIdx.x + threadIdx.x;
		j < N;
		j += blockDim.x * gridDim.x) {

		CValue_t Qipj;
		bool valid;
		CValue_t *Qip = cache_get_Q(ip, valid, STAGE_AREA_I); // staged for later use and update
		if (valid) { // reuse what we already have
			Qipj = Qip[j];
		}
		else {
			Qipj = cuda_evalQ(ip, j);
			Qip[j] = Qipj;
		}

		device_compute_nu_obj_diff(ip, in, j, Qipj, Gmaxp, Gmaxn, dh_obj_diff_array, result_idx);
	}
}

__global__ 
void cuda_compute_nu_obj_diff_SVR(GradValue_t Gmaxp, GradValue_t Gmaxn, CValue_t *dh_obj_diff_array, int *result_idx, int N)
{
	int ip = d_nu_solver.x;
	int in = d_nu_solver.y;

	for (int j = blockDim.x * blockIdx.x + threadIdx.x;
		j < N;
		j += blockDim.x * gridDim.x) {

		CValue_t Qipj1, Qipj2;
		bool valid;
		CValue_t *Qip = cache_get_Q(ip, valid, STAGE_AREA_I); // staged for later use and update
		if (valid) { // reuse what we already have
			Qipj1 = Qip[j];
			Qipj2 = Qip[j + d_l];
		}
		else {
			Qipj1 = cuda_evalQ(ip, j);
			Qip[j] = Qipj1;

			Qipj2 = -Qipj1;
			Qip[j + d_l] = Qipj2;
		}


		device_compute_nu_obj_diff(ip, in, j, Qipj1, Gmaxp, Gmaxn, dh_obj_diff_array, result_idx);
		device_compute_nu_obj_diff(ip, in, j + d_l, Qipj2, Gmaxp, Gmaxn, dh_obj_diff_array, result_idx);
	}
}


__global__ 
void cuda_find_nu_gmax(find_nu_gmax_param param, int N)
{
	D_NuGmaxReducer func(param.dh_gmaxp, param.dh_gmaxn, param.dh_gmaxp2, param.dh_gmaxn2, param.dh_gmaxp_idx, param.dh_gmaxn_idx,
		param.result_gmaxp, param.result_gmaxn, param.result_gmaxp2, param.result_gmaxn2, param.result_gmaxp_idx, param.result_gmaxn_idx);

	device_block_reducer(func, N);

	if (blockIdx.x == 0 && threadIdx.x == 0) {
		int ip, in;
		func.return_idx(ip, in);
		d_nu_solver.x = ip;
		d_nu_solver.y = in;
	}
}



__global__ 
void cuda_find_nu_min_idx(CValue_t *obj_diff_array, int *obj_diff_idx, CValue_t *result_obj_min, int *result_idx, int N)
{
	D_MinIdxReducer func(obj_diff_array, obj_diff_idx, result_obj_min, result_idx); // Class defined in CudaReducer.h
	device_block_reducer(func, N); // Template function defined in CudaReducer.h
	if (blockIdx.x == 0) {
		int j = func.return_idx();
		d_solver.y = j; /* Gmin_idx */
		if (d_y[j] == +1)
			d_solver.x = d_nu_solver.x; /* Gmaxp_idx */
		else
			d_solver.x = d_nu_solver.y; /* Gmaxn_idx */
	}
}

/************DEVICE KERNEL LAUNCHERS***************/
void launch_cuda_setup_x_square(size_t num_blocks, size_t block_size, int N)
{
	cuda_setup_x_square << <num_blocks, block_size >> >(N);
}

void launch_cuda_setup_QD(size_t num_blocks, size_t block_size, int N)
{
	cuda_setup_QD << <num_blocks, block_size >> >(N);
}


void launch_cuda_compute_obj_diff(size_t num_blocks, size_t block_size, GradValue_t Gmax, CValue_t *dh_obj_diff_array, int *result_idx, int N)
{
	cuda_compute_obj_diff << <num_blocks, block_size >> > (Gmax, dh_obj_diff_array, result_idx, N);
}

void launch_cuda_compute_obj_diff_SVR(size_t num_blocks, size_t block_size, GradValue_t Gmax, CValue_t *dh_obj_diff_array, int *result_idx, int N)
{
	cuda_compute_obj_diff_SVR << <num_blocks, block_size >> > (Gmax, dh_obj_diff_array, result_idx, N);
}

void launch_cuda_update_gradient(size_t num_blocks, size_t block_size, int N)
{
	cuda_update_gradient << <num_blocks, block_size >> > (N);
}

void launch_cuda_update_gradient_SVR(size_t num_blocks, size_t block_size, int N)
{
	cuda_update_gradient_SVR << <num_blocks, block_size >> > (N);
}

void launch_cuda_init_gradient(size_t num_blocks, size_t block_size, int start, int step, int N)
{
	cuda_init_gradient << < num_blocks, block_size>> > (start, step, N);
}

void launch_cuda_prep_gmax(size_t num_blocks, size_t block_size, GradValue_t *dh_gmax, GradValue_t *dh_gmax2, int *dh_gmax_idx, int N)
{
	cuda_prep_gmax << < num_blocks, block_size>> > (dh_gmax, dh_gmax2, dh_gmax_idx, N);
}

void launch_cuda_compute_alpha(size_t num_blocks, size_t block_size)
{
	cuda_compute_alpha << <num_blocks, block_size >> >();
}

void launch_cuda_update_alpha_status(size_t num_blocks, size_t block_size)
{
	cuda_update_alpha_status << <num_blocks, block_size >> >();
}

void launch_cuda_find_min_idx(size_t num_blocks, size_t block_size, size_t share_mem_size, CValue_t *obj_diff_array, int *obj_diff_idx, CValue_t *result_obj_min, int *result_idx, int N)
{
	cuda_find_min_idx << <num_blocks, block_size, share_mem_size >> >(obj_diff_array, obj_diff_idx, result_obj_min, result_idx, N);
}

void launch_cuda_find_gmax(size_t num_blocks, size_t block_size, size_t share_mem_size, find_gmax_param param, int N, bool debug)
{
	cuda_find_gmax << <num_blocks, block_size, share_mem_size >> >(param, N, debug);
}

void launch_cuda_find_nu_min_idx(size_t num_blocks, size_t block_size, size_t share_mem_size, CValue_t *obj_diff_array, int *obj_diff_idx, CValue_t *result_obj_min, int *result_idx, int N)
{
	cuda_find_nu_min_idx << <num_blocks, block_size, share_mem_size >> >(obj_diff_array, obj_diff_idx, result_obj_min, result_idx, N);
}

void launch_cuda_find_nu_gmax(size_t num_blocks, size_t block_size, size_t share_mem_size, find_nu_gmax_param param, int N)
{
	cuda_find_nu_gmax << <num_blocks, block_size, share_mem_size >> >(param, N);
}

void launch_cuda_compute_nu_obj_diff(size_t num_blocks, size_t block_size, GradValue_t Gmaxp, GradValue_t Gmaxn, CValue_t *dh_obj_diff_array, int *result_idx, int N)
{
	cuda_compute_nu_obj_diff << <num_blocks, block_size >> > (Gmaxp, Gmaxn, dh_obj_diff_array, result_idx, N);
}

void launch_cuda_compute_nu_obj_diff_SVR(size_t num_blocks, size_t block_size, GradValue_t Gmaxp, GradValue_t Gmaxn, CValue_t *dh_obj_diff_array, int *result_idx, int N)
{
	cuda_compute_nu_obj_diff_SVR << <num_blocks, block_size >> > (Gmaxp, Gmaxn, dh_obj_diff_array, result_idx, N);
}

void launch_cuda_prep_nu_gmax(size_t num_blocks, size_t block_size, GradValue_t *dh_gmaxp, GradValue_t *dh_gmaxn, GradValue_t *dh_gmaxp2, GradValue_t *dh_gmaxn2,
	int *dh_gmaxp_idx, int *dh_gmaxn_idx, int N)
{
	cuda_prep_nu_gmax << <num_blocks, block_size >> > (dh_gmaxp, dh_gmaxn, dh_gmaxp2, dh_gmaxn2, dh_gmaxp_idx, dh_gmaxn_idx, N);
}



/**************** DEBUGGING ********************/
/**
useful for peeking at various misc values when debugging
*/
__global__ 
void cuda_peek(int i, int j)
{
	printf("Q(%d,%d)=%g\n", i, j, cuda_evalQ(i, j));
}


