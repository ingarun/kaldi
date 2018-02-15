#!/bin/bash

# To be run from the s5/ directory.

. ./path.sh

set -e -o pipefail -u

# it should contain things like
# foo.txt, bar.txt, and dev.txt (dev.txt is a special filename that's
# obligatory).
data_dir=data/rnnlm
dir=exp/rnnlm
mkdir -p $data_dir/data
mkdir -p $dir

# make data dir
sort -R ~/data/althingi/pronDict_LM/LMtext_w_t131_split_on_EOS_expanded.txt > shuffled_lmtext.tmp
head -n 200000 shuffled_lmtext.tmp > data/rnnlm/data/dev.txt
tail -n +200001 shuffled_lmtext.tmp > data/rnnlm/data/train.txt
rm shuffled_lmtext.tmp

# validata data dir
rnnlm/validate_data_dir.py $data_dir/data

# get unigram counts
local/rnnlm/ensure_counts_present.sh $data_dir/data

# get vocab
mkdir -p $data_dir/vocab
rnnlm/get_vocab.py $data_dir/data > $data_dir/vocab/words.txt

# Choose weighting and multiplicity of data.
# The following choices would mean that data-source 'foo'
# is repeated once per epoch and has a weight of 0.5 in the
# objective function when training, and data-source 'bar' is repeated twice
# per epoch and has a data -weight of 1.5.
# There is no constraint that the average of the data weights equal one.
# Note: if a data-source has zero multiplicity, it just means you are ignoring
# it; but you must include all data-sources.
#cat > exp/foo/data_weights.txt <<EOF
#foo 1   0.5
#bar 2   1.5
#baz 0   0.0
#EOF
cat > $dir/data_weights.txt <<EOF
train 1   1.0
EOF

# get unigram probs
rnnlm/get_unigram_probs.py --vocab-file=$data_dir/vocab/words.txt \
                           --data-weights-file=$dir/data_weights.txt \
                           $data_dir/data > $dir/unigram_probs.txt

# choose features
rnnlm/choose_features.py --unigram-probs=$dir/unigram_probs.txt \
                         $data_dir/vocab/words.txt > $dir/features.txt
# validate features
rnnlm/validate_features.py $dir/features.txt

# make features for word
rnnlm/get_word_features.py --unigram-probs=$dir/unigram_probs.txt \
                         $data_dir/vocab/words.txt $dir/features.txt \
                         > $dir/word_feats.txt

# validate word features
rnnlm/validate_word_features.py --features-file $dir/features.txt \
                                $dir/word_feats.txt
