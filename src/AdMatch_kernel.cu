#include "src/nfa_kernels.h"

__constant__ int c_ad_transition_offset[SYMBOL_COUNT + 1];
__constant__ int c_ad_optimal_k_per_symbol[SYMBOL_COUNT + 1];

__global__ void admatch_kernel(unsigned char *input, int *input_offset,
                          ST_BLOCK *as_transition_table,
                          Transition *as_transition_list,
                          Transition *tko_transition_list,
                          int *tko_top_k_offset_per_symbol,
                          ST_BLOCK *tko_lim_vector,
                          ST_BLOCK *init_states_vector,
                          ST_BLOCK *final_states_vector,
                          int vector_len,
                          int state_count,
                          int wb_transition_count) {
    // Skip to the right input string
    input += input_offset[block_ID];
    // Get the size of current input string
    int input_bytes = input_offset[block_ID + 1] - input_offset[block_ID];

    extern __shared__ ST_BLOCK s_data[];  // shared memory

    ST_BLOCK *current_st_vec =
        s_data;  // current active states in shared memory
    ST_BLOCK *future_st_vec =
        s_data + vector_len;  // future active states in shared memory
    ST_BLOCK *workspace_vec = 
        s_data + 2*vector_len;

    Transition tuple = tko_transition_list[0];
    ST_T src_state, dst_state;
    ST_BLOCK src_bit, dst_bit;
    unsigned int src_block, dst_block;
    int c, transition_start, transition_count;

    // Copy initial and persistent states from global memory into shared memory
    for (int i = thread_ID; i < vector_len; i += thread_count) {
        current_st_vec[i] = init_states_vector[i];
        workspace_vec[i] = 0;
        future_st_vec[i] = 0;
    }

    __syncthreads();

    if (wb_transition_count == 0) goto BYPASS_HEAD;

    // If the first character is a word character, there is a word boundary
    // before the first character
    if (!is_word_char(input[0])) goto BYPASS_HEAD;

    // For each transition triggered by word boundary
    for (int i = thread_ID; i < wb_transition_count; i += thread_count) {
        tuple = as_transition_list[i];
        src_state = tuple.src;
        dst_state = tuple.dst;
        src_bit =
            1 << (src_state %
                  bit_sizeof(ST_BLOCK));  // index of state bit inside the block
        dst_bit = 1 << (dst_state % bit_sizeof(ST_BLOCK));
        src_block = src_state / bit_sizeof(ST_BLOCK);  // index of state block
        dst_block = dst_state / bit_sizeof(ST_BLOCK);

        // If transition source is set in current active state vector
        // (divergence happens here)
        if (src_bit & current_st_vec[src_block]) {
            // Set transition destination in CURRENT active state vector
            atomicOr(&current_st_vec[dst_block], dst_bit);
        }
    }

    __syncthreads();

BYPASS_HEAD:
    // For each byte in the input string
    for (int byt = 0; byt < input_bytes; byt++) {
        int local_active_num = 0;
        for (int i = thread_ID; i < vector_len; i += thread_count) {
            future_st_vec[i] = 0;
            local_active_num += __popc(current_st_vec[i]);
        }
        __syncthreads();

        local_active_num = blockReduceSum(local_active_num);

        c = (int)(input[byt]);
        if ( (c_ad_optimal_k_per_symbol[c+1] - c_ad_optimal_k_per_symbol[c])>local_active_num){
            // For each transition triggered by the character
            for (int blk = 0; blk < vector_len; blk++) {
                int tmp = current_st_vec[blk];
                while (tmp) {
                    int pos = __ffs(tmp);
                    tmp = tmp ^ (1<<(pos-1));
                    pos = blk * bit_sizeof(ST_BLOCK) + pos-1;
                    for (int i = thread_ID; i < vector_len;
                        i += thread_count) {
                        future_st_vec[i] |=
                            as_transition_table[c * state_count * vector_len +
                                                pos * vector_len + i];
                }
                __syncthreads();
                }
            }
        }
        else{
            for (int i = c_ad_optimal_k_per_symbol[c]; i < c_ad_optimal_k_per_symbol[c+1]; i++) {
                int offset = tko_top_k_offset_per_symbol[i];
                for (int j = thread_ID; j < vector_len; j += thread_count) {
                    workspace_vec[j] =
                        tko_lim_vector[i * vector_len + j] & current_st_vec[j];
                }
                __syncthreads();

                int sign = 1 - 2 * (offset < 0);  // -1-> negative 1->positive
                int left_1 = max(int(0), int(offset / bit_sizeof(ST_BLOCK)));
                int right_1 =
                    min(int(vector_len - 1),
                        int(vector_len - 1 + (offset / bit_sizeof(ST_BLOCK))));
                int left_2 = max(int(0), int(offset / bit_sizeof(ST_BLOCK) + sign));
                int right_2 = min(
                    int(vector_len - 1),
                    int(vector_len - 1 + sign + (offset / bit_sizeof(ST_BLOCK))));

                if (offset >= 0) {
                    for (int j = left_1 + thread_ID; j <= right_1;
                        j += thread_count) {
                        future_st_vec[j] |=
                            (workspace_vec[j - offset / bit_sizeof(ST_BLOCK)]
                            << (offset % bit_sizeof(ST_BLOCK)));
                    }
                    __syncthreads();

                    for (int j = left_2 + thread_ID; j <= right_2;
                        j += thread_count) {
                        future_st_vec[j] |=
                            (workspace_vec[j - offset / bit_sizeof(ST_BLOCK) - 1] >>
                            (bit_sizeof(ST_BLOCK) -
                            (offset % bit_sizeof(ST_BLOCK))));
                    }
                    __syncthreads();

                } else {
                    for (int j = left_1 + thread_ID; j <= right_1;
                        j += thread_count) {
                        future_st_vec[j] |=
                            (workspace_vec[j - (offset / bit_sizeof(ST_BLOCK))] >>
                            (((-offset) % bit_sizeof(ST_BLOCK))));
                    }
                    __syncthreads();

                    for (int j = left_2 + thread_ID; j <= right_2;
                        j += thread_count) {
                        future_st_vec[j] |=
                            (workspace_vec[j - (offset / bit_sizeof(ST_BLOCK)) + 1]
                            << ((bit_sizeof(ST_BLOCK) -
                                ((-offset) % bit_sizeof(ST_BLOCK)))));
                    }
                    __syncthreads();
                }
            }

            transition_start = c_ad_transition_offset[c];
            transition_count = c_ad_transition_offset[c + 1] - transition_start;

            // For each transition triggered by the character
            for (int i = thread_ID; i < transition_count; i += thread_count) {
                tuple = tko_transition_list[i + transition_start];
                src_state = tuple.src;
                dst_state = tuple.dst;
                src_bit =
                    1 << (src_state %
                        bit_sizeof(
                            ST_BLOCK));  // index of state bit inside the block
                dst_bit = 1 << (dst_state % bit_sizeof(ST_BLOCK));
                src_block =
                    src_state / bit_sizeof(ST_BLOCK);  // index of state block
                dst_block = dst_state / bit_sizeof(ST_BLOCK);

                // If transition source is set in current active state vector
                // (divergence happens here)
                if (src_bit & current_st_vec[src_block]) {
                    // Set transition destination in future active state vector
                    atomicOr(&future_st_vec[dst_block], dst_bit);
                }
            }
        }

        // Swap current and future active state vector
        if (current_st_vec == s_data) {
            current_st_vec = s_data + vector_len;
            future_st_vec = s_data;
        } else {
            current_st_vec = s_data;
            future_st_vec = s_data + vector_len;
        }

        __syncthreads();

        // No transition triggered by word boundary
        if (wb_transition_count == 0) continue;

        // If there is NOT a word boundary between input[byt] and input[byt + 1]
        // or after the last character
        if ((byt < input_bytes - 1 &&
             (is_word_char(input[byt]) ^ is_word_char(input[byt + 1])) == 0) ||
            (byt == input_bytes - 1 && !is_word_char(input[input_bytes - 1])))
            continue;

        // For each transition triggered by word boundary
        for (int i = thread_ID; i < wb_transition_count; i += thread_count) {
            tuple = as_transition_list[i];
            src_state = tuple.src;
            dst_state = tuple.dst;
            src_bit =
                1 << (src_state %
                      bit_sizeof(
                          ST_BLOCK));  // index of state bit inside the block
            dst_bit = 1 << (dst_state % bit_sizeof(ST_BLOCK));
            src_block =
                src_state / bit_sizeof(ST_BLOCK);  // index of state block
            dst_block = dst_state / bit_sizeof(ST_BLOCK);

            // If transition source is set in current active state vector
            // (divergence happens here)
            if (src_bit & current_st_vec[src_block]) {
                // Set transition destination in CURRENT active state vector
                atomicOr(&current_st_vec[dst_block], dst_bit);
            }
        }
        __syncthreads();
    }

    // Copy final active states from shared memory into global memory
    for (int i = thread_ID; i < vector_len; i += thread_count) {
        final_states_vector[block_ID * vector_len + i] = current_st_vec[i];
    }
}

// Host function to run iNFAnt algorithm on GPU
// This function can process multiple strings on a NFA simultaneously
// tg                   :  NFA transition graph
// h_input_array        :  array of input string in host memory
// input_bytes_array    :  array of string length
// array_size           :  array size (# of strings to match)
// threads_per_block    :  # of threads per block for kernel function
// show_match_result    :  print regex matching result if this variable is true
void run_AD(struct ad_scratch &scratch, unsigned char **h_input_array,
            int *input_bytes_array, int array_size, int threads_per_block,
            bool show_match_result, bool profiler_mode,
            vector<int> *accept_rules) {
    struct timeval start_time, end_time;
    cudaEvent_t memalloc_start,
        memalloc_end;  // start and end events of device memory allocation
    cudaEvent_t memcpy_h2d_start,
        memcpy_h2d_end;  // start and end events of memory copy from host to
                         // device
    cudaEvent_t kernel_start,
        kernel_end;  // start and end events of kernel execution
    cudaEvent_t memcpy_d2h_start,
        memcpy_d2h_end;  // start and end events of memory copy from device to
                         // host
    cudaEvent_t memfree_start,
        memfree_end;  // start and end events of device memory free

    int vec_len = scratch.as_scratch->tg->init_states_vector
                      .block_count;  // length (# of blocks) of state vector
    int total_input_bytes = 0;       // sum of string length

    // Variables in host memory
    unsigned char *h_input;              // total input string
    int h_input_offset[array_size + 1];  // offsets of all input strings
    ST_BLOCK *h_final_st_vec;            // final active states of all strings

    // Variables in device memory
    unsigned char *d_input;  // total input string
    int *d_input_offset;     // offset of each input string
    ST_BLOCK *d_final_st_vec;

    // Create events
    if (profiler_mode) {
        cudaEventCreate(&memalloc_start);
        cudaEventCreate(&memalloc_end);
        cudaEventCreate(&memcpy_h2d_start);
        cudaEventCreate(&memcpy_h2d_end);
        cudaEventCreate(&kernel_start);
        cudaEventCreate(&kernel_end);
        cudaEventCreate(&memcpy_d2h_start);
        cudaEventCreate(&memcpy_d2h_end);
        cudaEventCreate(&memfree_start);
        cudaEventCreate(&memfree_end);

        gettimeofday(&start_time, NULL);
    }

    for (int i = 0; i < array_size; i++) {
        h_input_offset[i] = total_input_bytes;
        total_input_bytes += input_bytes_array[i];
    }
    h_input_offset[array_size] = total_input_bytes;

    h_input = (unsigned char *)malloc(total_input_bytes);
    if (!h_input) {
        cerr << "Error: allocate host memory to store total input string"
             << endl;
        exit(-1);
    }

    // Copy each string into h_input to construct a big string
    for (int i = 0; i < array_size; i++) {
        memcpy(h_input + h_input_offset[i], h_input_array[i],
               input_bytes_array[i]);
    }

    // Allocate host memory
    h_final_st_vec =
        (ST_BLOCK *)malloc(sizeof(ST_BLOCK) * vec_len * array_size);
    if (!h_final_st_vec) {
        cerr << "Error: allocate host memory to store final state vectors"
             << endl;
        exit(-1);
    }

    // Allocate device memory
    if (profiler_mode) cudaEventRecord(memalloc_start, 0);
    cudaMalloc((void **)&d_input, total_input_bytes);
    cudaMalloc((void **)&d_input_offset, sizeof(int) * (array_size + 1));
    cudaMalloc((void **)&d_final_st_vec,
               sizeof(ST_BLOCK) * vec_len * array_size);
    if (profiler_mode) cudaEventRecord(memalloc_end, 0);

    // Copy input from host memory into device memory
    if (profiler_mode) cudaEventRecord(memcpy_h2d_start, 0);
    cudaMemcpy(d_input, h_input, total_input_bytes, cudaMemcpyHostToDevice);
    cudaMemcpy(d_input_offset, h_input_offset, sizeof(int) * (array_size + 1),
               cudaMemcpyHostToDevice);
    if (cudaSuccess != cudaMemcpyToSymbol(c_ad_transition_offset,
            scratch.tko_scratch->tg->offset_per_symbol,
            sizeof(int) * (SYMBOL_COUNT + 1))) {
    cout << "Error!\n";
    exit(-1);
    }
    if (cudaSuccess != cudaMemcpyToSymbol(c_ad_optimal_k_per_symbol,
            scratch.tko_scratch->tg->optimal_k_per_symbol,
            sizeof(int) * (SYMBOL_COUNT + 1))) {
    cout << "Error!\n";
    exit(-1);
    }
    if (profiler_mode) cudaEventRecord(memcpy_h2d_end, 0);

    // Calculate the size of shared memory (for 3 state vectors and transition
    // offset)
    int shem = 3 * vec_len * sizeof(ST_BLOCK);

    // Launch kernel
    if (profiler_mode) cudaEventRecord(kernel_start, 0);
    // cudaDeviceSetCacheConfig(cudaFuncCachePreferShared);
    // cudaDeviceSetSharedMemConfig(cudaSharedMemBankSizeFourByte);
    admatch_kernel<<<array_size, threads_per_block, shem>>>(d_input,
        d_input_offset,
        scratch.as_scratch->d_transition_table,
        scratch.as_scratch->d_transition_list,
        scratch.tko_scratch->d_transition_list,
        scratch.tko_scratch->d_top_k_offset_per_symbol,
        scratch.tko_scratch->d_lim_vec,
        scratch.as_scratch->d_init_st_vec,
        d_final_st_vec,
        vec_len,
        scratch.as_scratch->tg->state_count,
        scratch.as_scratch->tg->wb_transition_count);
    if (profiler_mode) cudaEventRecord(kernel_end, 0);
    if (profiler_mode) cudaEventSynchronize(kernel_end);

    // Copy result from device memory into host memory
    if (profiler_mode) cudaEventRecord(memcpy_d2h_start, 0);
    cudaMemcpy(h_final_st_vec, d_final_st_vec,
               sizeof(ST_BLOCK) * vec_len * array_size, cudaMemcpyDeviceToHost);
    if (profiler_mode) cudaEventRecord(memcpy_d2h_end, 0);

    // Get final active states and accept rules for each string
    vector<ST_T> final_states[array_size];
    // vector<int> accept_rules[array_size];
    unordered_map<ST_T, vector<int>>::iterator itr;

    for (int i = 0; i < array_size; i++) {
        get_active_states(h_final_st_vec + i * vec_len, vec_len,
                          final_states[i]);
        // Get all accept rules for string i
        for (int j = 0; j < final_states[i].size(); j++) {
            // Get accept rules triggered by this state
            itr = scratch.as_scratch->tg->accept_states_rules.find(final_states[i][j]);
            if (itr != scratch.as_scratch->tg->accept_states_rules.end()) {
                accept_rules[i].insert(accept_rules[i].end(),
                                       itr->second.begin(), itr->second.end());
            }
        }
        // Remove repeated accept rules for string i
        sort(accept_rules[i].begin(), accept_rules[i].end());
        accept_rules[i].erase(
            unique(accept_rules[i].begin(), accept_rules[i].end()),
            accept_rules[i].end());
    }

    // Free device memory
    if (profiler_mode) cudaEventRecord(memfree_start, 0);
    cudaFree(d_input);
    cudaFree(d_input_offset);
    cudaFree(d_final_st_vec);
    if (profiler_mode) cudaEventRecord(memfree_end, 0);

    // Free host memory
    free(h_final_st_vec);
    free(h_input);

    if (profiler_mode) gettimeofday(&end_time, NULL);

    if (show_match_result) show_results(array_size, final_states, accept_rules);
    if (profiler_mode) {
        Profiler(start_time, end_time, array_size, memalloc_start, memalloc_end,
                 memcpy_h2d_start, memcpy_h2d_end, kernel_start, kernel_end,
                 memcpy_d2h_start, memcpy_d2h_end, memfree_start, memfree_end);
    }

    // Destroy events
    if (profiler_mode) {
        cudaEventDestroy(memalloc_start);
        cudaEventDestroy(memalloc_end);
        cudaEventDestroy(memcpy_h2d_start);
        cudaEventDestroy(memcpy_h2d_end);
        cudaEventDestroy(kernel_start);
        cudaEventDestroy(kernel_end);
        cudaEventDestroy(memcpy_d2h_start);
        cudaEventDestroy(memcpy_d2h_end);
        cudaEventDestroy(memfree_start);
        cudaEventDestroy(memfree_end);
    }
}



/***************************************************************************
#include "src/nfa_kernels.h"

__global__ void admatch_kernel(unsigned char *input, int *input_offset,
                           Transition *infa_transition_list, 
                           int *infa_transition_offset,
                           ST_BLOCK *infa_persis_states_vector,
                           ST_BLOCK *init_states_vector,
                           ST_BLOCK *final_states_vector,
                           int vector_len) {
    // Skip to the right input string
    input += input_offset[block_ID];
    // Get the size of current input string
    int input_bytes = input_offset[block_ID + 1] - input_offset[block_ID];

    extern __shared__ ST_BLOCK s_data[];  // shared memory

    ST_BLOCK *current_st_vec =
        s_data;  // current active states in shared memory
    ST_BLOCK *future_st_vec =
        s_data + vector_len;  // future active states in shared memory
    ST_BLOCK *persis_st_vec =
        s_data + 2 * vector_len;  // persistent states in shared memory
    int *s_transition_offset =
        (int *)(s_data + 3 * vector_len);  // transition offset in shared memory

    Transition tuple = infa_transition_list[0];
    ST_T src_state, dst_state;
    ST_BLOCK src_bit, dst_bit;
    unsigned int src_block, dst_block;
    int c, transition_start, transition_count, wb_transition_start,
        wb_transition_count;

    // Copy initial and persistent states from global memory into shared memory
    for (int i = thread_ID; i < vector_len; i += thread_count) {
        current_st_vec[i] = init_states_vector[i];
        persis_st_vec[i] = infa_persis_states_vector[i];
    }

    // Copy transition offset from global memory into shared memory
    // Note that there are SYMBOL_COUNT + 1 elements in total
    for (int i = thread_ID; i <= SYMBOL_COUNT; i += thread_count) {
        s_transition_offset[i] = infa_transition_offset[i];
    }

    __syncthreads();

    // First transition and # of transitions triggered by word boundary
    wb_transition_start = s_transition_offset[WORD_BOUNDARY];
    wb_transition_count =
        s_transition_offset[WORD_BOUNDARY + 1] - wb_transition_start;

    if (wb_transition_count == 0) goto BYPASS_HEAD;

    // If the first character is a word character, there is a word boundary
    // before the first character
    if (!is_word_char(input[0])) goto BYPASS_HEAD;

    // For each transition triggered by word boundary
    for (int i = thread_ID; i < wb_transition_count; i += thread_count) {
        tuple = infa_transition_list[i + wb_transition_start];
        src_state = tuple.src;
        dst_state = tuple.dst;
        src_bit =
            1 << (src_state %
                  bit_sizeof(ST_BLOCK));  // index of state bit inside the block
        dst_bit = 1 << (dst_state % bit_sizeof(ST_BLOCK));
        src_block = src_state / bit_sizeof(ST_BLOCK);  // index of state block
        dst_block = dst_state / bit_sizeof(ST_BLOCK);

        // If transition source is set in current active state vector
        // (divergence happens here)
        if (src_bit & current_st_vec[src_block]) {
            // Set transition destination in CURRENT active state vector
            atomicOr(&current_st_vec[dst_block], dst_bit);
        }
    }

    __syncthreads();

BYPASS_HEAD:
    // For each byte in the input string
    for (int byt = 0; byt < input_bytes; byt++) {
        // Keep persistent states active
        // future_st_vec <- current_st_vec & persis_st_vec
        for (int i = thread_ID; i < vector_len; i += thread_count) {
            future_st_vec[i] = current_st_vec[i] & persis_st_vec[i];
        }
        __syncthreads();

        c = (int)(input[byt]);
        transition_start = s_transition_offset[c];
        transition_count = s_transition_offset[c + 1] - transition_start;

        // For each transition triggered by the character
        for (int i = thread_ID; i < transition_count; i += thread_count) {
            tuple = infa_transition_list[i + transition_start];
            src_state = tuple.src;
            dst_state = tuple.dst;
            src_bit =
                1 << (src_state %
                      bit_sizeof(
                          ST_BLOCK));  // index of state bit inside the block
            dst_bit = 1 << (dst_state % bit_sizeof(ST_BLOCK));
            src_block =
                src_state / bit_sizeof(ST_BLOCK);  // index of state block
            dst_block = dst_state / bit_sizeof(ST_BLOCK);

            // If transition source is set in current active state vector
            // (divergence happens here)
            if (src_bit & current_st_vec[src_block]) {
                // Set transition destination in future active state vector
                atomicOr(&future_st_vec[dst_block], dst_bit);
            }
        }

        // Swap current and future active state vector
        if (current_st_vec == s_data) {
            current_st_vec = s_data + vector_len;
            future_st_vec = s_data;
        } else {
            current_st_vec = s_data;
            future_st_vec = s_data + vector_len;
        }

        __syncthreads();

        // No transition triggered by word boundary
        if (wb_transition_count == 0) continue;

        // If there is NOT a word boundary between input[byt] and input[byt + 1]
        // or after the last character
        if ((byt < input_bytes - 1 &&
             (is_word_char(input[byt]) ^ is_word_char(input[byt + 1])) == 0) ||
            (byt == input_bytes - 1 && !is_word_char(input[input_bytes - 1])))
            continue;

        // For each transition triggered by word boundary
        for (int i = thread_ID; i < wb_transition_count; i += thread_count) {
            tuple = infa_transition_list[i + wb_transition_start];
            src_state = tuple.src;
            dst_state = tuple.dst;
            src_bit =
                1 << (src_state %
                      bit_sizeof(
                          ST_BLOCK));  // index of state bit inside the block
            dst_bit = 1 << (dst_state % bit_sizeof(ST_BLOCK));
            src_block =
                src_state / bit_sizeof(ST_BLOCK);  // index of state block
            dst_block = dst_state / bit_sizeof(ST_BLOCK);

            // If transition source is set in current active state vector
            // (divergence happens here)
            if (src_bit & current_st_vec[src_block]) {
                // Set transition destination in CURRENT active state vector
                atomicOr(&current_st_vec[dst_block], dst_bit);
            }
        }

        __syncthreads();
    }

    // Copy final active states from shared memory into global memory
    for (int i = thread_ID; i < vector_len; i += thread_count) {
        final_states_vector[block_ID * vector_len + i] = current_st_vec[i];
    }
}

void run_AD(struct ad_scratch &scratch, unsigned char **h_input_array,
              int *input_bytes_array, int array_size, int threads_per_block,
              bool show_match_result, bool profiler_mode,
              vector<int> *accept_rules) {
    struct timeval start_time, end_time;
    cudaEvent_t memalloc_start,
        memalloc_end;  // start and end events of device memory allocation
    cudaEvent_t memcpy_h2d_start,
        memcpy_h2d_end;  // start and end events of memory copy from host to
                         // device
    cudaEvent_t kernel_start,
        kernel_end;  // start and end events of kernel execution
    cudaEvent_t memcpy_d2h_start,
        memcpy_d2h_end;  // start and end events of memory copy from device to
                         // host
    cudaEvent_t memfree_start,
        memfree_end;  // start and end events of device memory free

    int vec_len = scratch.infa_scratch->tg->init_states_vector
                      .block_count;  // length (# of blocks) of state vector
    int total_input_bytes = 0;       // sum of string length

    // Variables in host memory
    unsigned char *h_input;              // total input string
    int h_input_offset[array_size + 1];  // offsets of all input strings
    ST_BLOCK *h_final_st_vec;            // final active states of all strings

    // Variables in device memory
    unsigned char *d_input;  // total input string
    int *d_input_offset;     // offset of each input string
    ST_BLOCK *d_final_st_vec;

    // Create events
    if (profiler_mode) {
        cudaEventCreate(&memalloc_start);
        cudaEventCreate(&memalloc_end);
        cudaEventCreate(&memcpy_h2d_start);
        cudaEventCreate(&memcpy_h2d_end);
        cudaEventCreate(&kernel_start);
        cudaEventCreate(&kernel_end);
        cudaEventCreate(&memcpy_d2h_start);
        cudaEventCreate(&memcpy_d2h_end);
        cudaEventCreate(&memfree_start);
        cudaEventCreate(&memfree_end);

        gettimeofday(&start_time, NULL);
    }
    for (int i = 0; i < array_size; i++) {
        h_input_offset[i] = total_input_bytes;
        total_input_bytes += input_bytes_array[i];
    }
    h_input_offset[array_size] = total_input_bytes;

    h_input = (unsigned char *)malloc(total_input_bytes);
    if (!h_input) {
        cerr << "Error: allocate host memory to store total input string"
             << endl;
        exit(-1);
    }

    // Copy each string into h_input to construct a big string
    for (int i = 0; i < array_size; i++) {
        memcpy(h_input + h_input_offset[i], h_input_array[i],
               input_bytes_array[i]);
    }

    // Allocate host memory
    h_final_st_vec =
        (ST_BLOCK *)malloc(sizeof(ST_BLOCK) * vec_len * array_size);
    if (!h_final_st_vec) {
        cerr << "Error: allocate host memory to store final state vectors"
             << endl;
        exit(-1);
    }

    // Allocate device memory
    if (profiler_mode) cudaEventRecord(memalloc_start, 0);
    cudaMalloc((void **)&d_input, total_input_bytes);
    cudaMalloc((void **)&d_input_offset, sizeof(int) * (array_size + 1));
    cudaMalloc((void **)&d_final_st_vec,
               sizeof(ST_BLOCK) * vec_len * array_size);
    if (profiler_mode) cudaEventRecord(memalloc_end, 0);

    // Copy input from host memory into device memory
    if (profiler_mode) cudaEventRecord(memcpy_h2d_start, 0);
    cudaMemcpy(d_input, h_input, total_input_bytes, cudaMemcpyHostToDevice);
    cudaMemcpy(d_input_offset, h_input_offset, sizeof(int) * (array_size + 1),
               cudaMemcpyHostToDevice);
    if (profiler_mode) cudaEventRecord(memcpy_h2d_end, 0);

    // Calculate the size of shared memory (for 3 state vectors and transition
    // offset)
    int shem =
        3 * vec_len * sizeof(ST_BLOCK) + sizeof(int) * (SYMBOL_COUNT + 1);

    // Launch kernel
    if (profiler_mode) cudaEventRecord(kernel_start, 0);
    admatch_kernel<<<array_size, threads_per_block, shem>>>(
        d_input, d_input_offset, 
        scratch.infa_scratch.d_transition_list,
        scratch.infa_scratch.d_persis_st_vec,
        scratch.infa_scratch.d_transition_offset, 
        scratch.infa_scratch.d_init_st_vec,
        d_final_st_vec,
        vec_len);
    if (profiler_mode) cudaEventRecord(kernel_end, 0);
    if (profiler_mode) cudaEventSynchronize(kernel_end);

    // Copy result from device memory into host memory
    if (profiler_mode) cudaEventRecord(memcpy_d2h_start, 0);
    cudaMemcpy(h_final_st_vec, d_final_st_vec,
               sizeof(ST_BLOCK) * vec_len * array_size, cudaMemcpyDeviceToHost);
    if (profiler_mode) cudaEventRecord(memcpy_d2h_end, 0);

    // Get final active states and accept rules for each string
    vector<ST_T> final_states[array_size];
    // vector<int> accept_rules[array_size];
    unordered_map<ST_T, vector<int>>::iterator itr;

    for (int i = 0; i < array_size; i++) {
        get_active_states(h_final_st_vec + i * vec_len, vec_len,
                          final_states[i]);
        // Get all accept rules for string i
        for (int j = 0; j < final_states[i].size(); j++) {
            // Get accept rules triggered by this state
            itr = scratch.infa_scratch.tg->accept_states_rules.find(final_states[i][j]);
            if (itr != scratch.infa_scratch.tg->accept_states_rules.end()) {
                accept_rules[i].insert(accept_rules[i].end(),
                                       itr->second.begin(), itr->second.end());
            }
        }
        // Remove repeated accept rules for string i
        sort(accept_rules[i].begin(), accept_rules[i].end());
        accept_rules[i].erase(
            unique(accept_rules[i].begin(), accept_rules[i].end()),
            accept_rules[i].end());
    }

    // Free device memory
    if (profiler_mode) cudaEventRecord(memfree_start, 0);
    cudaFree(d_input);
    cudaFree(d_input_offset);
    cudaFree(d_final_st_vec);
    if (profiler_mode) cudaEventRecord(memfree_end, 0);

    // Free host memory
    free(h_final_st_vec);
    free(h_input);

    if (profiler_mode) gettimeofday(&end_time, NULL);

    if (show_match_result) show_results(array_size, final_states, accept_rules);

    if (profiler_mode) {
        Profiler(start_time, end_time, array_size, memalloc_start, memalloc_end,
                 memcpy_h2d_start, memcpy_h2d_end, kernel_start, kernel_end,
                 memcpy_d2h_start, memcpy_d2h_end, memfree_start, memfree_end);
    }

    // Destroy events
    if (profiler_mode) {
        cudaEventDestroy(memalloc_start);
        cudaEventDestroy(memalloc_end);
        cudaEventDestroy(memcpy_h2d_start);
        cudaEventDestroy(memcpy_h2d_end);
        cudaEventDestroy(kernel_start);
        cudaEventDestroy(kernel_end);
        cudaEventDestroy(memcpy_d2h_start);
        cudaEventDestroy(memcpy_d2h_end);
        cudaEventDestroy(memfree_start);
        cudaEventDestroy(memfree_end);
    }
}
***************************************************************************/