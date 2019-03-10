#ifndef ITA_REGEX_H
#define ITA_REGEX_H

#include <vector>
#include "src/transition_graph.h"

using namespace std;

// flags: contain basic configurations
typedef unsigned short int ITA_FLAGS;

// Kernel Selection
#define INFA_KERNEL 1
#define AS_KERNEL (1 << 1)
#define TKO_KERNEL (1 << 2)

// Profiler mode on/off
#define PROFILER_MODE (1 << 3)

// Show results on/off
#define SHOW_RESULTS (1 << 4)

// Scratch is the workspace of kernels
// Using Scratch allows 
//      1. fewer gpu-memory malloc/memcpy, reduce the time cost of scan
//      2. decouple the part of preparing transition graph and scan
struct ita_scratch {
    ita_scratch(ITA_FLAGS flags, char *nfa);
    ITA_FLAGS flag;
    TransitionGraph *tg;
    Transition *d_transition_list;  // list of transition (source,
                                    // destination) tuples
    int *d_transition_offset;
    int *d_top_k_offset_per_symbol;
    ST_BLOCK *d_init_st_vec, *d_persis_st_vec, *d_lim_vec;  // state vectors
    ST_BLOCK *d_transition_table;
};

// alloc gpu-mem and record them in scratch
void allocScratch(struct ita_scratch &scratch);

// free gpu-mem
void freeScratch(struct ita_scratch &scratch);

// single input string scan, results of match will be recorded into accepted_rules
// this scan mode looks like most CPU-end regex-engine like pcre/re2/hyperscan
// but please remember:
//      sequential mode is much less effective than batched mode
void Scan(struct ita_scratch &scratch, char *text, vector<int> *accepted_rules);

// batched input strings scan, much more efficient
// Use this mode whenever possible! larger batch size (str_count), higher efficiency
void BatchedScan(struct ita_scratch &scratch, char **text, int *text_len,
                 int str_count, vector<int> *accepted_rules);

#endif
