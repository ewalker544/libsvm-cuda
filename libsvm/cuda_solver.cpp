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
** Description: Cuda implementation of Sequential Minimal Optimization (SMO) solver
** @author: Ed Walker
*/
#include "cuda_solver.h"
#include "svm_device.h"
#include "sparse_bit_vector.h"
#include <memory>

CudaSolver *cudaSolver;

/****** MinIdxReducer *********/
class CudaSolver::MinIdxReducer
{
private:
	CValue_t *input_array, *output_array;
	int *input_idx, *output_idx;

public:
	MinIdxReducer(CValue_t *obj_diff_array, int *obj_diff_idx, CValue_t *result_obj_min, int *result_idx)
		: input_array(obj_diff_array), output_array(result_obj_min), input_idx(obj_diff_idx), output_idx(result_idx)
	{}

	void compute(size_t reduce_blocks, size_t reduce_block_size, int N)
	{
		size_t share_mem_size = reduce_block_size*(sizeof(CValue_t) + sizeof(int));
		launch_cuda_find_min_idx(reduce_blocks, reduce_block_size, share_mem_size, input_array, input_idx, output_array, output_idx, N);
		check_cuda_kernel_launch("fail in cuda_find_min_idx");
	}

	void swap()
	{
		std::swap(input_array, output_array);
		std::swap(input_idx, output_idx);
	}

	int process_output()
	{
		// int Gmin_idx = -1; 
		// cudaMemcpy(&Gmin_idx, &output_idx[0], sizeof(int), cudaMemcpyDeviceToHost); // Gmin_idx should be in the first position now
		return -1;
	}
};

/******* GmaxReducer *********/
class CudaSolver::GmaxReducer
{
private:
	GradValue_t *input_array1, *output_array1; // Gmax
	GradValue_t *input_array2, *output_array2; // Gmax2
	int *input_idx, *output_idx; // Gmax_idx
	GradValue_t Gmax, Gmax2;
	bool debug;

public:
	GmaxReducer(GradValue_t *dh_gmax, GradValue_t *dh_gmax2, int *dh_gmax_idx, GradValue_t *result_gmax, GradValue_t *result_gmax2, int *result_gmax_idx, bool debug=false)
		: input_array1(dh_gmax), input_array2(dh_gmax2), input_idx(dh_gmax_idx), output_array1(result_gmax), output_array2(result_gmax2), output_idx(result_gmax_idx), debug(debug)
	{}

	void compute(size_t reduce_blocks, size_t reduce_block_size, int N)
	{
		size_t share_mem_size = reduce_block_size*(2 * sizeof(GradValue_t) + sizeof(int));
		find_gmax_param param;
		param.dh_gmax = input_array1;
		param.dh_gmax2 = input_array2;
		param.dh_gmax_idx = input_idx;
		param.result_gmax = output_array1;
		param.result_gmax2 = output_array2;
		param.result_gmax_idx = output_idx;
		logtrace("TRACE: GmaxReducer::compute: share_mem_size=%d, reduce_blocks=%d, reduce_block_size=%d, N=%d\n",
			share_mem_size, reduce_blocks, reduce_block_size, N);
		launch_cuda_find_gmax(reduce_blocks, reduce_block_size, share_mem_size, param, N, debug);
		check_cuda_kernel_launch("fail in cuda_find_gmax");
	}

	void swap()
	{
		std::swap(input_array1, output_array1);
		std::swap(input_array2, output_array2);
		std::swap(input_idx, output_idx);
	}

	int process_output()
	{
		/* int Gmax_idx = -1;
		   check_cuda_return("fail to copy output_idx from device",
		   cudaMemcpy(&Gmax_idx, &output_idx[0], sizeof(int), cudaMemcpyDeviceToHost)); */
		check_cuda_return("fail to copy output_array1 from device",
			cudaMemcpy(&Gmax, &output_array1[0], sizeof(GradValue_t), cudaMemcpyDeviceToHost));
		check_cuda_return("fail to copy output_array2 from device",
			cudaMemcpy(&Gmax2, &output_array2[0], sizeof(GradValue_t), cudaMemcpyDeviceToHost));
		return -1;
	}

	void get_gmax_values(GradValue_t &ret_Gmax, GradValue_t &ret_Gmax2)
	{
		ret_Gmax = Gmax;
		ret_Gmax2 = Gmax2;
	}
};

/****** Initialization methods ***********/
void CudaSolver::init_obj_diff_space(int l)
{
	dh_obj_diff_array = make_unique_cuda_array<CValue_t>(l);
	dh_obj_diff_idx = make_unique_cuda_array<int>(l);
	dh_result_obj_diff = make_unique_cuda_array<CValue_t>(num_blocks);
	dh_result_idx = make_unique_cuda_array<int>(num_blocks);
	return;
}

void CudaSolver::init_gmax_space(int l)
{
	dh_gmax = make_unique_cuda_array<GradValue_t>(l);
	dh_gmax2 = make_unique_cuda_array<GradValue_t>(l);
	dh_gmax_idx = make_unique_cuda_array<int>(l);
	dh_result_gmax = make_unique_cuda_array<GradValue_t>(num_blocks);
	dh_result_gmax2 = make_unique_cuda_array<GradValue_t>(num_blocks);
	dh_result_gmax_idx = make_unique_cuda_array<int>(num_blocks);
	return;
}

void CudaSolver::find_launch_parameters(int &num_blocks, int &block_size, int N)
{
	int bsize = THREADS_PER_BLOCK;
	while (true) {
		if (bsize > 2 * WARP_SIZE) {
			int nblocks = N / bsize;
			if (nblocks < 50) // number of blocks still too small
				bsize >>= 1; // halve it
			else
				break; // number of blocks at least 50
		}
		else
			break; // threads per block too small
	}

	block_size = bsize;
	num_blocks = (N + block_size - 1) / block_size;
}

void CudaSolver::init_memory_arrays(int l) 
{
	find_launch_parameters(num_blocks, block_size, l);

	if (!quiet_mode) {
		std::cout << "CUDA Integration\n";
		std::cout << "----------------\n";
		std::cout << "Selected thread block size:         " << block_size << std::endl;
		std::cout << "Selected number of blocks:          " << num_blocks << std::endl;
		std::cout << "Problem size:                       " << l << std::endl;
		std::cout << "Gradient vector stored as:          " << typeid(GradValue_t).name() << std::endl;
	}

	result_idx.reset(new int[num_blocks]);
	result_obj_diff.reset(new CValue_t[num_blocks]);
	result_gmax.reset(new GradValue_t[num_blocks]);
	result_gmax2.reset(new GradValue_t[num_blocks]);

	init_obj_diff_space(l);
	init_gmax_space(l);
}

void CudaSolver::setup_solver(const SChar_t *y, double *G, double *alpha, char *alpha_status, double Cp, double Cn, int active_size)
{
	/*
	** Note: svm_problem.l may not be equal to this active_size.  
	** In regression analysis, active_size == 2 * svm_problem.l in SMO Solver. 
	*/
	clock_t now = clock(); // DEBUG

	// sets up all the cuda device arrays
	init_memory_arrays(active_size);

	cudaError_t err;

	// allocate space for labels
	dh_y = make_unique_cuda_array<SChar_t>(active_size);

	err = cudaMemcpy(&dh_y[0], y, sizeof(SChar_t) * active_size, cudaMemcpyHostToDevice);
	check_cuda_return("fail to copy to device for dh_y", err);

	dh_QD = make_unique_cuda_array<CValue_t>(active_size);

	/** allocate space for gradient vector */
	dh_G = make_unique_cuda_array<GradValue_t>(active_size);
	{
		std::unique_ptr<GradValue_t[]> h_G(new GradValue_t[active_size]);
		for (int i = 0; i < active_size; ++i)
			h_G[i] = static_cast<GradValue_t>(G[i]);

		err = cudaMemcpy(&dh_G[0], &h_G[0], sizeof(GradValue_t) * active_size, cudaMemcpyHostToDevice);
		check_cuda_return("fail to copy to device for dh_G", err);
	}

	dh_alpha = make_unique_cuda_array<GradValue_t>(active_size);
	{
		std::unique_ptr<GradValue_t[]> h_alpha(new GradValue_t[active_size]);
		for (int i = 0; i < active_size; ++i)
			h_alpha[i] = static_cast<GradValue_t>(alpha[i]);

		err = cudaMemcpy(&dh_alpha[0], &h_alpha[0], sizeof(GradValue_t) * active_size, cudaMemcpyHostToDevice);
		check_cuda_return("fail to copy to device for dh_alpha", err);
	}

	dh_alpha_status = make_unique_cuda_array<char>(active_size);
	cudaMemcpy(&dh_alpha_status[0], alpha_status, sizeof(char) * active_size, cudaMemcpyHostToDevice);
	check_cuda_return("fail to copy to device for dh_alpha_status", err);

	/** setup constants */
	err = update_solver_variables(&dh_y[0], &dh_QD[0], &dh_G[0], &dh_alpha[0], &dh_alpha_status[0], Cp, Cn);
	check_cuda_return("fail to setup constants/textures", err);

	check_cuda_return("fail in initializing device", cudaDeviceSynchronize());

	/* Initialise gradient vector on device */
	int step; // Initialize step d_G entries at a time 
	// NOTE: This can take awhile, so some devices may time out.  Adjust this value accordingly.
	if (CUDA_ARCH >= 300) {
	    step = std::min(maxGridSize, active_size); 
	} else {
		step = 500;
	}
	int start = 0;	// Starting index of d_G to update.
	int left = active_size;

	do {
		step = std::min(step, left);
		if (CUDA_ARCH >= 300) {
			init_device_gradient2(block_size, start, step, active_size);
		} else {
			init_device_gradient1(block_size, start, step, active_size);
		}
		start += step;
		left -= step;
	} while (left > 0);

	int nblocks, bsize;
	find_launch_parameters(nblocks, bsize, l);
	launch_cuda_setup_QD(nblocks, bsize, l);
	check_cuda_kernel_launch("fail in cuda_setup_QD");

	setup_LRU_cache(active_size);

#if DEBUG_CHECK
	show_memory_usage(mem_size);
#endif

	dbgprintf(true, "CudaSolver::setup_solver: elapsed time = %f\n", (float)(clock() - now) / CLOCKS_PER_SEC); 
	startup_time = clock() - startup_time;
	dbgprintf(true, "CudaSolver: Total startup time = %f s\n", (float)(startup_time) / CLOCKS_PER_SEC);

	return;
}

void CudaSolver::setup_rbf_variables(int l)
{
	if (kernel_type != RBF)
		return;

	clock_t now = clock(); // DEBUG
	cudaError_t err;
	dh_x_square = make_unique_cuda_array<CValue_t>(l);

	err = update_rbf_variables(&dh_x_square[0]);
	check_cuda_return("fail to update rbf variables", err);
		
	int nblocks, bsize;
	find_launch_parameters(nblocks, bsize, l);
	launch_cuda_setup_x_square(nblocks, bsize, l); 
	check_cuda_kernel_launch("fail in cuda_setup_x_square");

	dbgprintf(true, "CudaSolver::setup_rbf_variables: elapsed time = %f\n", (float)(clock() - now) / CLOCKS_PER_SEC); // DEBUG
}

void CudaSolver::show_memory_usage(const int &total_space)
{
	printf("Total space allocated on device:	%d\n", total_space);
	int devNum;
	cudaGetDevice(&devNum);
	cudaDeviceProp devProp;
	cudaGetDeviceProperties(&devProp, devNum);
	printf("Total global memory:                %lu\n", devProp.totalGlobalMem);
	printf("Percentage allocated:               %f%%\n", (double)total_space / devProp.totalGlobalMem * 100);
}

/**
 * Initializes the LRU column cache
 * */
void CudaSolver::setup_LRU_cache(int active_size)
{
	int space = static_cast<int>(cache_size * (1 << 20)); // megabytes
	int num_elements = space / sizeof(CValue_t); // compute the number of CValue_t elements to cache
	int num_columns = (num_elements + active_size-1) / active_size; // compute ceiling of number of columns to cache
	num_columns = std::max(5, num_columns); // cache at least 5 columns
	space = num_columns * active_size; // re-compute the number of bytes owe want to cache
	dh_column_space = make_unique_cuda_array<CValue_t>(space);
	dh_columns = make_unique_cuda_array<CacheNode*>(active_size);
	{
		std::unique_ptr<CacheNode*[]> h_columns(new CacheNode*[active_size]);
		for (int i = 0; i < active_size; i++)
			h_columns[i] = NULL;
		cudaMemcpy(&dh_columns[0], &h_columns[0], active_size * sizeof(CacheNode*), cudaMemcpyHostToDevice);
	}
	setup_device_LRU_cache(&dh_columns[0], &dh_column_space[0], space, active_size);
}

/**
Loads: kernel_type, svm_type, gamma, coef0, degree, x
*/
void CudaSolver::load_problem_parameters(const svm_problem &prob, const svm_parameter &param)
{
	cudaError_t err;
	svm_node **x = prob.x;
	int l = prob.l;

	cache_size = param.cache_size;

	/** allocate space for support vectors */
#if USE_BITVECTOR_FORMAT
	int bitvector_size;
#if !USE_SPARSE_BITVECTOR_FORMAT
	int max_dim = -1;
#endif
#endif
	int elements = 0;
	for (int i = 0; i < l; ++i)
	{
		const svm_node *tmp = x[i];
		while (tmp->index != -1) { // row terminator
#if USE_BITVECTOR_FORMAT
#if !USE_SPARSE_BITVECTOR_FORMAT
			max_dim = std::max(max_dim, tmp->index); // index always starts from "1"
#endif
#endif
			++elements; // count each row svm_node element
			++tmp;
		}
		++elements; // count the row terminating svm_node
	}

#if USE_BITVECTOR_FORMAT
#if !USE_SPARSE_BITVECTOR_FORMAT
	int max_words = (max_dim + WORD_SIZE-1) / WORD_SIZE;

	dh_sparse_vector = make_unique_cuda_array<uint32_t>(l*max_words);
#endif
#endif

	dbgprintf(true, "load_problem_parameters: %d elements need to be moved to device\n", elements);

#define TRANSFER_CHUNK_SIZE		100000000
	/**
	NOTE: cuda_svm_node is typedef to float2
	float2.x == svm_node.index
	float2.y == svm_node.value
	*/
	dh_space = make_unique_cuda_array<cuda_svm_node>(elements);
	{

#if USE_BITVECTOR_FORMAT
#if USE_SPARSE_BITVECTOR_FORMAT
		SparseBitVector bit_vector(elements); // elements is our initial guess of the size of the sparse bit vector
		std::unique_ptr<int[]> h_bitvector_table(new int[l]);
		dh_bitvector_table = make_unique_cuda_array<int>(l);
#else
		std::unique_ptr<uint32_t[]> h_sparse_vector(new uint32_t[l*max_words]);
		memset(&h_sparse_vector[0], 0, l*max_words*sizeof(uint32_t));
#endif
#endif

		int next_loc = 0; // index in dh_space to move elements too
		int j = 0; // index for x_space
		int transfer_chunk = std::min(TRANSFER_CHUNK_SIZE, elements);
		std::unique_ptr<cuda_svm_node[]> x_space(new cuda_svm_node[transfer_chunk]); 
		for (int i = 0; i < l; ++i) {
#if USE_BITVECTOR_FORMAT
#if USE_SPARSE_BITVECTOR_FORMAT
			h_bitvector_table[i] = bit_vector.get_pos();
#else
			size_t pattern_offset = i * max_words;
#endif
#endif
			const svm_node *tmp = x[i];
			while (tmp->index != -1) {

#if USE_BITVECTOR_FORMAT
				int idx = tmp->index-1; // index always starts from 1
#if USE_SPARSE_BITVECTOR_FORMAT
				bit_vector.set(idx); // set the index in the sparse bit vector
#else
				h_sparse_vector[pattern_offset + idx / WORD_SIZE] |= (1 << (idx%WORD_SIZE)); 
#endif
#endif

#if !USE_BITVECTOR_FORMAT
				x_space[j].y = static_cast<float>(tmp->index); // in the LIBSVM SPARSE format, we send over the index
#endif
				x_space[j].x = static_cast<float>(tmp->value);

				++tmp;
				++j;
				if (j == transfer_chunk) {
					// x_space is full, time to transfer to device
					err = cudaMemcpy(&dh_space[next_loc], &x_space[0], j * sizeof(cuda_svm_node), cudaMemcpyHostToDevice);
					check_cuda_return("fail to copy to device for dh_space", err);
					next_loc += j; // next position in dh_space to fill
					j = 0; // reset index
				}
			}

#if !USE_BITVECTOR_FORMAT
			x_space[j++].y = -1;
#else
			x_space[j++].x = -1;
#if USE_SPARSE_BITVECTOR_FORMAT
			bit_vector.set(SparseBitVector::sentinel); // mark the end of the bit vector for this SV
#endif
#endif

			if (j == transfer_chunk) {
				// x_space is full, time to transfer to device
				err = cudaMemcpy(&dh_space[next_loc], &x_space[0], j * sizeof(cuda_svm_node), cudaMemcpyHostToDevice);
				check_cuda_return("fail to copy to device for dh_space", err);
				next_loc += j;  // next position in dh_space to fill
				j = 0; // reset
			}
		}
		if (j > 0) {
			err = cudaMemcpy(&dh_space[next_loc], &x_space[0], j * sizeof(cuda_svm_node), cudaMemcpyHostToDevice);
			check_cuda_return("fail to copy to device for dh_space", err);
		}

#if USE_BITVECTOR_FORMAT
#if USE_SPARSE_BITVECTOR_FORMAT
		// copy bit vector table
		err = cudaMemcpy(&dh_bitvector_table[0], &h_bitvector_table[0], l * sizeof(int), cudaMemcpyHostToDevice);
		check_cuda_return("fail to copy to device for dh_bitvector_table", err);
	
		uint32_t *h_sparse_vector = bit_vector.get_buffer(bitvector_size);
		dbgprintf(true, "load_problem_parameters: sparse bit vector size is %d\n", bitvector_size);

		dh_sparse_vector = make_unique_cuda_array<uint32_t>(bitvector_size);
		dbgprintf(true, "load_problem_parameters: created dh_sparse_vector of size %d\n", bitvector_size);
#else
		bitvector_size = l * max_words;
#endif
		err = cudaMemcpy(&dh_sparse_vector[0], &h_sparse_vector[0], bitvector_size * sizeof(uint32_t), cudaMemcpyHostToDevice);
		check_cuda_return("fail to copy to device for dh_sparse_vector", err);
#endif
	}

	dbgprintf(true, "load_problem_parameters: setting up dh_x\n");
	dh_x = make_unique_cuda_array<int>(l);
	{
		int j = 0;
		std::unique_ptr<int[]> h_x(new int[l]);
		for (int i = 0; i < l; ++i) {
			h_x[i] = j;
			const svm_node *tmp = x[i];
			while (tmp->index != -1) {
				++j;
				++tmp;
			}
			j++;
		}
		err = cudaMemcpy(&dh_x[0], &h_x[0], sizeof(int) * l, cudaMemcpyHostToDevice);
		check_cuda_return("fail to copy to device for dh_x", err);
	}

	err = update_param_constants(param, &dh_x[0], &dh_space[0], sizeof(cuda_svm_node)*elements, prob.l);
	check_cuda_return("fail to setup parameter constants", err);

#if USE_BITVECTOR_FORMAT
#if USE_SPARSE_BITVECTOR_FORMAT
	err = update_sparse_vector(&dh_sparse_vector[0], bitvector_size * sizeof(uint32_t), &dh_bitvector_table[0], l * sizeof(int), -1);
#else
	err = update_sparse_vector(&dh_sparse_vector[0], bitvector_size * sizeof(uint32_t), NULL, -1, max_words);
#endif
	check_cuda_return("fail to setup sparse bit vector", err);
#endif
}

CudaSolver::CudaSolver(const svm_problem &prob, const svm_parameter &param, bool quiet_mode)
	: l(prob.l), eps(param.eps), kernel_type(param.kernel_type), svm_type(param.svm_type), mem_size(0), quiet_mode(quiet_mode)
{
	int deviceNum;
	cudaGetDevice(&deviceNum);
	cudaDeviceProp deviceProp;
	cudaError_t err = cudaGetDeviceProperties(&deviceProp, deviceNum);
	if (err != cudaSuccess) {
		std::cerr << "FATAL ERROR: unable to get CUDA device version!\n";
		exit(1);
	}
	CUDA_ARCH = deviceProp.major * 100 + deviceProp.minor * 10;
	maxGridSize = deviceProp.maxGridSize[1]; // store the maximum grid size for dimension 1

	startup_time = clock();
	dbgprintf(true, "CudaSolver: GO!\n"); // DEBUG
	try {
		load_problem_parameters(prob, param);		
	}
	catch (std::exception &e) {
		std::cerr << "Fail to load problem parameters: " << e.what() << std::endl;
		cudaDeviceReset();
		exit(1);
	}
	dbgprintf(true, "CudaSolver::CudaSolver: elapsed time = %f \n", (float)(clock() - startup_time)/CLOCKS_PER_SEC); // DEBUG
}

CudaSolver::~CudaSolver()
{
	unbind_texture();
	cudaDeviceReset();
}

/****** Compute methods **********/
void CudaSolver::compute_alpha()
{
	logtrace("TRACE: compute_alpha\n");
	launch_cuda_compute_alpha(1, 1);
	check_cuda_kernel_launch("fail in cuda_compute_alpha");
}

void CudaSolver::update_alpha_status()
{
	logtrace("TRACE: update_alpha_status\n");
	launch_cuda_update_alpha_status(1, 1);
	check_cuda_kernel_launch("fail in cuda_update_alpha_status");
}

void CudaSolver::select_working_set_j(GradValue_t Gmax, int l)
{
	logtrace("TRACE: select_working_set_j: num_blocks=%d block_size=%d\n", num_blocks, block_size);

	if (svm_type == EPSILON_SVR) { 
		// for SVR we only need to compute for half the working set, because the other half is symmetric
		int nblocks = (num_blocks + 1) / 2;
		launch_cuda_compute_obj_diff_SVR(nblocks, block_size, Gmax, &dh_obj_diff_array[0], &dh_obj_diff_idx[0], l/2);
	}
	else {
		launch_cuda_compute_obj_diff(num_blocks, block_size, Gmax, &dh_obj_diff_array[0], &dh_obj_diff_idx[0], l);
	}
	check_cuda_kernel_launch("fail in cuda_compute_obj_diff");

	logtrace("TRACE: select_working_set_j: starting cross_block_reducer\n");

	MinIdxReducer func(&dh_obj_diff_array[0], &dh_obj_diff_idx[0], &dh_result_obj_diff[0], &dh_result_idx[0]);
	cross_block_reducer(block_size, func, l);

	logtrace("TRACE: select_working_set_j: done!\n");
	return ;
}


int CudaSolver::select_working_set(int &out_i, int &out_j, int l)
{
	logtrace("TRACE: select_working_set: l = %d\n", l);
	GradValue_t Gmax = -GRADVALUE_MAX; // -INF;
	GradValue_t Gmax2 = -GRADVALUE_MAX; // -INF;

	launch_cuda_prep_gmax (num_blocks, block_size, &dh_gmax[0], &dh_gmax2[0], &dh_gmax_idx[0], l);
	check_cuda_kernel_launch("fail in cuda_prep_gmax");

	logtrace("TRACE: select_working_set: done preparing for finding gmax\n");

	GmaxReducer func(&dh_gmax[0], &dh_gmax2[0], &dh_gmax_idx[0], &dh_result_gmax[0], 
		&dh_result_gmax2[0], &dh_result_gmax_idx[0]);

	cross_block_reducer(block_size, func, l);

	func.get_gmax_values(Gmax, Gmax2);

	if (Gmax + Gmax2 < eps) {
		return 1;
	}

	select_working_set_j(Gmax, l);

	return 0;
}

void CudaSolver::update_gradient(int l)
{
	logtrace("TRACE: update_gradient: l = %d\n", l);
	if (svm_type == EPSILON_SVR || svm_type == NU_SVR) { 
		// for SVR we only need to compute half the working set, because the other half is symmetric
		int nblocks = (num_blocks + 1) / 2;
		launch_cuda_update_gradient_SVR(nblocks, block_size, l / 2);
	}
	else {
		launch_cuda_update_gradient(num_blocks, block_size, l);
	}
	check_cuda_kernel_launch("fail in cuda_update_gradient");
}

void CudaSolver::fetch_vectors(double *G, double *alpha, char *alpha_status, int l)
{
	cudaError_t err;
	{
		std::unique_ptr<GradValue_t[]> h_G(new GradValue_t[l]);
		err = cudaMemcpy(&h_G[0], &dh_G[0], sizeof(GradValue_t) * l, cudaMemcpyDeviceToHost);
		check_cuda_return("fail to copy from device dh_G", err);
		for (int i = 0; i < l; ++i)
			G[i] = h_G[i];
	}
	{
		std::unique_ptr<GradValue_t[]> h_alpha(new GradValue_t[l]);
		err = cudaMemcpy(&h_alpha[0], &dh_alpha[0], sizeof(GradValue_t) * l, cudaMemcpyDeviceToHost);
		check_cuda_return("fail to copy from device dh_alpha", err);
		for (int i = 0; i < l; ++i)
			alpha[i] = h_alpha[i];
	}

	err = cudaMemcpy(alpha_status, &dh_alpha_status[0], sizeof(char) * l, cudaMemcpyDeviceToHost);
	check_cuda_return("fail to copy from device dh_alpha_status", err);

	show_device_cache_stats();
}


