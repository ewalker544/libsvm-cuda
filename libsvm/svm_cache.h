
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

** Description: Implementation of lock-less LRU cache
** @author: Ed Walker
*/
#ifndef _SVM_LRU_CACHE_H_
#define _SVM_LRU_CACHE_H_
#include "svm_defs.h"

#define COLLECT_CACHE_STATS	0

#define SERIALIZE(block) do {if (blockIdx.x == 0 && threadIdx.x == 0) {block;}} while(0)

struct LRUList {
	struct CacheNode *head; // node at the front of the list
	struct CacheNode *tail; // node at the end of the list
	int size; // number of nodes we have in the list

	__device__ LRUList() : head(NULL), tail(NULL), size(0) {}

	__device__ void push_front(CacheNode *n) {
		if (head == NULL) {
			head = tail = n;
		}
		else {
			n->next = head;
			head->prev = n;
			head = n; // n is the new head
		}
		++size;
	}

	__device__ void push_back(CacheNode *n) {
		if (tail == NULL) {
			head = tail = n;
		}
		else {
			n->prev = tail;
			tail->next = n;
			tail = n; // n is the new tail
		}
		++size;
	}

	__device__ void remove(CacheNode *n) {
		// modify head and tail
		if (size == 1) {
			head = tail = NULL; // empty the list
		}
		else if (n == head) {
			head = n->next; // move the head to the next position
		}
		else if (n == tail) {
			tail = n->prev; // move the tail to the previous positon
		}

		// modify the links of the double-linked list
		if (n->next) { // modify the node in front of n (n->next)
			n->next->prev = n->prev;
		}
		if (n->prev) { // modify the node behind of n (n->prev)
			n->prev->next = n->next;
		}

		// reset the node links
		n->next = NULL;
		n->prev = NULL;

		--size;
	}


	__device__ void dump() {
		printf("LRU: ");
		for (CacheNode *tmp = head; tmp != NULL; tmp = tmp->next) {
			printf("%d ", tmp->col_idx);
		}
		printf("\n");
	}
};

__device__		LRUList			*d_LRU_cache;
__device__		CacheNode		**d_columns;
__device__		CacheNode		*d_staging_area[2];

#if COLLECT_CACHE_STATS
__device__		int				d_cache_hits;
__device__		int				d_cache_misses;
#endif

enum StageArea_t {STAGE_AREA_I = 0, STAGE_AREA_J = 1};

/**
States
------
   ->STAGE_I: two scenerios - a cache node could be found (hit) for column I, or a cache node could be reclaimed for caching column I
  |     |
  |     V
  |  STAGE_J: two scenerios - a cache node cound be found (hit) for column J, or a cache node, not used in STAGE_I, be reclaimed for cacheing column J
  |     |
  |     V
   --COMMIT: move the staged columns I and J to the front of the LRU list
*/
enum CacheStates_t {STAGE_I = 0, STAGE_J = 1, COMMIT = 3};

#if COLLECT_CACHE_STATS
__device__ __forceinline__
static void cache_hit()
{
	SERIALIZE(++d_cache_hits);
}

__device__ __forceinline__
static void cache_miss()
{
	SERIALIZE(++d_cache_misses);
}

__device__ __forceinline__
static void init_cache_counters()
{
	d_cache_misses = d_cache_hits = 0;
}

__global__ 
static void show_cache_stats()
{
	int total = d_cache_hits + d_cache_misses;

	printf("Cache: hits = %d, misses = %d, efficiency = %f%%\n", d_cache_hits, d_cache_misses,
		(total > 0 ? (double)d_cache_hits / (double)(total)* 100 : 0));

	printf("Number of CacheNodes = %d\n", d_LRU_cache->size);
}
#else
#define cache_hit()
#define cache_miss()
#define init_cache_counters()
#endif

void show_device_cache_stats()
{
#if COLLECT_CACHE_STATS
	show_cache_stats << <1, 1 >> >();
#endif
}

/*
Creates a new cache node.
Note: we have this instead of a CacheNode constructor because we don't want to define a device function in svm_defs.h header
*/
__device__ __forceinline__ 
static CacheNode *NewCacheNode(CValue_t * buffer)
{
	CacheNode *n = new CacheNode();
	n->column = buffer;
	n->col_idx = -1;
	n->stage_idx = -1;
	n->used = false;
	n->next = NULL;
	n->prev = NULL;
	return n;
}

__device__ 
static void init_LRU_cache(CValue_t *dh_column_space, int space, int col_size)
{
	d_LRU_cache = new LRUList();

	int offset = 0;
	while (space >= col_size) {
		CValue_t *buffer = &dh_column_space[offset];

		offset += col_size;
		space -= col_size;

		CacheNode *n = NewCacheNode(buffer); // create new node to store a column buffer
		
		d_LRU_cache->push_back(n); // add this to the end of the list
	}
}

__global__ 
static void setup_LRU_cache(CacheNode **dh_columns, CValue_t *dh_column_space, int space, int col_size)
{
	d_staging_area[STAGE_AREA_I] = d_staging_area[STAGE_AREA_J] = NULL;
	d_columns = dh_columns;

	init_LRU_cache(dh_column_space, space, col_size);

	init_cache_counters();
}

void setup_device_LRU_cache(CacheNode **dh_columns, CValue_t *dh_column_space, int space, int col_size)
{
	setup_LRU_cache << <1, 1 >> >(dh_columns, dh_column_space, space, col_size);
}

__device__ 
static CValue_t *cache_get_Q(int col, bool &valid, StageArea_t stage_area)
{
	CacheNode *n = d_columns[col];
	if (n && n->stage_idx == -1) { // valid cache node and not being staged
		valid = true;
		SERIALIZE(
			n->used = true; // indicate that this column is being read
			d_staging_area[stage_area] = n; // put this in the staging area for later access
		);
		cache_hit();
	}
	else {
		valid = false;

		// pick a buffer from the end (last recently used) of the cache
		if (stage_area == STAGE_AREA_I) {
			// State: STAGE_I --> STAGE_J
			// Pre-condition: all cache nodes are available for eviction
			n = d_LRU_cache->tail; // for I we pick the last to evict
		} 
		else {
			// State: STAGE_J --> COMMIT
			// Pre-condition: a cache node may be being read or modified by column I

			// select a cache node that is not being staged for ANOTHER column (i.e. I) AND not being read
			n = d_LRU_cache->tail;	
			while ((n->stage_idx != -1 && n->stage_idx != col) ||
				n->used) {
				n = n->prev;
			}
		}

		SERIALIZE(
			n->stage_idx = col; // mark this cache node as being staged (new data will be written to it) for column col
			d_staging_area[stage_area] = n; // put this in the staging area for later access
			if (n->col_idx != -1)			// remove from column table
				d_columns[n->col_idx] = NULL;
			n->col_idx = col;				// remember where I am now assigned too
		);

		cache_miss();
	}

	return n->column; // return the buffer associated with this cache node
}

__device__ 
static CValue_t *cache_get_Stage(int i, StageArea_t stage_area)
{
	if (d_staging_area[stage_area] && d_staging_area[stage_area]->col_idx == i)
		return d_staging_area[stage_area]->column;
	else
		return NULL;
}

__device__ __forceinline__ 
static void cache_commit_StageArea(int col, StageArea_t stage_area) 
{
	CacheNode *n = d_staging_area[stage_area];
	if (n == NULL || n->col_idx != col)
		return ;

	d_LRU_cache->remove(n); // remove n from its position on the LRU list

	n->col_idx = col; // reassign it to a new column 
	n->used = false; // no longer being read
	n->stage_idx = -1; // no longer being modified
	d_columns[col] = n; // assign it to its new position in the table

	d_LRU_cache->push_front(n); // now put it in front of the LRU list

	d_staging_area[stage_area] = NULL; // empty the staging area

}

__device__ 
static void cache_commit_Stages(int i, int j)
{
	// State: COMMIT --> STAGE_I
	// Pre-condition: staging areas STAGE_I and STAGE_J are ready to commit
	// Note: only one thread should update the LRU cache
	SERIALIZE(
		cache_commit_StageArea(i, STAGE_AREA_I);
		cache_commit_StageArea(j, STAGE_AREA_J);
	);
}


#endif
