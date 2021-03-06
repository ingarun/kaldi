# coding: utf-8

import sys
import codecs

# 2017 Inga Rún
# Punctuator maps all numbers to the token <NUM>.
# To re-insert the numbers I use the text coming from punctuator, the list
# of numbers mapped to <NUM>, the index for where in the list to start (0 for dev files, for eval files it is the last index used for the dev files plus one) and an output file, which will contain the text with numbers.
# If run from ~/punctuator/example:
# srun python local/re-inserting-numbers.py out/punctuator_dev.txt out/numbers.txt 0 out/final_punctuated_dev.txt
# NOTE! In the future I'll have num_ind=0. Now dev and test files are not preprocessed together anymore. Keep this like it is for now. Remember to change!

num_ind = int(sys.argv[3])
with codecs.open(sys.argv[4], 'w', 'utf-8') as out_txt:
    with codecs.open(sys.argv[2], 'r', 'utf-8') as num_txt:
        with codecs.open(sys.argv[1], 'r', 'utf-8') as text:

            textlist = text.read().strip().split()
            numlist = num_txt.read().strip().split('\n')
            indices = [i for i, x in enumerate(textlist) if x == "<NUM>"]

            for index in indices:
                textlist[index] = numlist[num_ind]
                num_ind+=1
    print "Last index used in the number list: ", num_ind-1            
    out_txt.write(' '.join(textlist) + '\n')
