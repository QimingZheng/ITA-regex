#ifndef ITA_KERNEL
#define ITA_KERNEL

#include<vector>
typedef unsigned short int ITA_FLAGS;

#define INFA_KERNEL 1
#define AS_KERNEL (1 << 1)
#define TKO_KERNEL (1 << 2)
#define PROFILER_MODE (1 << 3)

void Scan(ITA_FLAGS flag, char *nfa, char *text, vector<int> *accepted_rules);

void BatchedScan(ITA_FLAGS flag, char *nfa, unsigned char *text, int *text_len, int str_count, vector<int> *accepted_rules);

#endif