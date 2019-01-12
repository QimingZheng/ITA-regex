#include <iostream>
#include <stdlib.h>
#include <string>
#include <vector>
#include "string.h"

#include "ITA_regex.h"

using namespace std;

void usage(char *program)
{
        cerr << "usage: " << program << " nfa_file input_string string_count [-s] [-p]" << endl;
        cerr << "               -s: show regex matching result" << endl;
        cerr << "               -p: show profiling results" << endl;
}

int main(int argc, char **argv)
{
        bool show_match_result = false, profiler_mode = false;

        if (argc < 4 || argc > 6)
        {
                usage(argv[0]);
                return EXIT_FAILURE;
        }

        if(argc>=5){
                if (strcmp(argv[4], "-s") && strcmp(argv[4], "-p"))
                        return EXIT_FAILURE;
                if (!strcmp(argv[4], "-s"))
                        show_match_result = 1;
                if (!strcmp(argv[4], "-p"))
                        profiler_mode = 1;
        }

        if (argc == 6)
        {
                if (strcmp(argv[5], "-s") && strcmp(argv[5], "-p"))
                        return EXIT_FAILURE;
                if (!strcmp(argv[5], "-s"))
                        show_match_result = 1;
                if (!strcmp(argv[5], "-p"))
                        profiler_mode = 1;
        }

        int string_count = atoi(argv[3]);
        if (string_count <= 0)
        {
                cerr << "Error: invalid string_count value " << string_count << endl;
                return EXIT_FAILURE;
        }

        // Run regex matching on GPU
        char *h_input_array[string_count];   // array of string
        int input_bytes_array[string_count]; // array of string length

        for (int i = 0; i < string_count; i++)
        {
                h_input_array[i] = argv[2];
                input_bytes_array[i] = string_count;
        }

        vector<int> accepted_rules[string_count];

        BatchedScan(INFA_KERNEL | (profiler_mode ? PROFILER_MODE : 0) | (show_match_result ? SHOW_RESULTS : 0),
                    argv[1], h_input_array,
                    input_bytes_array,
                    string_count,
                    accepted_rules);

        return EXIT_SUCCESS;
}