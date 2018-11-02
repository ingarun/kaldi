#!/bin/bash -e

# Copyright 2017  Reykjavik University (Author: Inga Rún Helgadóttir)
# Apache 2.0

# Expand abbreviations and numbers in the texts to use for training and testing.
# In this script the expansion fst is not adapted to the input text

set -o pipefail

nj=64
stage=-1
order=4

echo "$0 $@"  # Print the command line for logging

. ./cmd.sh
. ./path.sh
. utils/parse_options.sh
. local/utils.sh
. ./conf/path.conf

text_norm_lex=local/thraxgrammar/lex
base_norm_data=$root_expansionLM_cs_data
base_norm_model=$root_base_text_norm_model

if [ $# != 2 ]; then
  echo "Text normalize training corpora, i.e. expand numbers and abbreviations"
  echo "using the basic expansion language model, based on the Leipzig corpora"
  echo "and a small Althingi data set."
  echo ""
  echo "Usage: local/expand.sh [options] <input-text-file> <output-text-file>"
  echo "e.g.: local/expand.sh data/all/text_bb_SpellingFixed.txt data/all/text"
fi

infile=$1
outfile=$2
dir=$(dirname $infile);
mkdir -p ${dir}/split$nj/

for f in $infile ${base_norm_data}/numbertexts_althingi100.txt.gz \
  ${text_norm_lex}/abbr_lexicon.txt $base_norm_model/{baseLM_words.txt,base_expand_to_words.fst,base_expansionLM_${order}g.fst}; do
  [ ! -f $f ] && echo "$0: expected $f to exist" && exit 1;
done  

if [ $stage -le 1 ]; then
  if [ $nj -gt 1 ]; then
    echo "We want to process it in parallel."
    IFS=$' \t\n'
    split_text=$(for j in `seq 1 $nj`; do printf "${dir}/split%s/cleantext.%s.txt " $nj $j; done)
    # The upper condition applies to the ASR training/testing texts and
    # the lower one applies to the LM training texts.
    if grep -q "rad[0-9]" ${infile}; then
      utils/split_scp.pl $infile $split_text || exit 1; # the field separator has to be correct
    else
      # I need to add IDs to get the utterances on a Kaldi format
      awk '{printf("%010d %s\n", NR, $0)}' $infile > ${dir}/cleantext_wID.txt
      utils/split_scp.pl ${dir}/cleantext_wID.txt $split_text || exit 1;
    fi
  else
    cp $infile ${dir}/split1/cleantext.1.txt
  fi
fi

if [ $stage -le 2 ]; then
  echo "Make a list over all the words in numbertexts if necessary"
  if [ ! -f ${base_norm_data}/wordlist_numbertexts_althingi100.txt ]; then
    gzip -cd ${base_norm_data}/numbertexts_althingi100.txt.gz | cut -d" " -f2- | tr " " "\n" | grep -v "^\s*$" | sort -u > ${base_norm_data}/wordlist_numbertexts_althingi100.txt
  elif [ ${base_norm_data}/wordlist_numbertexts_althingi100.txt -ot ${base_norm_data}/numbertexts_althingi100.txt.gz ]; then
    gzip -cd ${base_norm_data}/numbertexts_althingi100.txt.gz | cut -d" " -f2- | tr " " "\n" | grep -v "^\s*$" | sort -u > ${base_norm_data}/wordlist_numbertexts_althingi100.txt
  fi
fi

if [ $stage -le 3 ]; then
  echo "Extract words that are only in the althingi texts, excluding unexpanded abbrs, numbers and punctuations."
  echo "Map words which are not seen in context in numbertexts to <word>."
  for i in `seq 1 $nj`; do
    cut -d" " -f2- ${dir}/split${nj}/cleantext.${i}.txt | tr " " "\n" | grep -v "^\s*$" | sort -u > ${dir}/split${nj}/words_cleantext.${i}.tmp
    # Extract words that are only in the althingi texts, excluding unexpanded abbrs, numbers and punctuations
    comm -23 <(comm -23 ${dir}/split${nj}/words_cleantext.${i}.tmp ${base_norm_data}/wordlist_numbertexts_althingi100.txt | egrep -v "[^A-ZÁÐÉÍÓÚÝÞÆÖa-záðéíóúýþæö]") <(cut -f1 ${text_norm_lex}/abbr_lexicon.txt | sort -u) > ${dir}/split${nj}/words_job${i}_only.tmp
  done

  # Map words which are not seen in context in numbertexts to <word>
  source venv3/bin/activate
  #pip install nltk
  utils/slurm.pl JOB=1:$nj ${dir}/split${nj}/log/save-OOVwords.JOB.log python3 local/save_OOVwords.py ${dir}/split${nj}/cleantext.JOB.txt ${dir}/split${nj}/words_jobJOB_only.tmp ${dir}/split${nj}/cleantext_afterWordMapping.JOB.txt ${dir}/split${nj}/mappedWords_jobJOB.txt
  # I get problems if encounter more than one space between words after the thrax step. Temporary fix is this:
  for i in `seq 1 $nj`; do
    sed -r -i 's:([0-9]) (%|‰|\.):\1\2:g' ${dir}/split${nj}/cleantext_afterWordMapping.${i}.txt
  done
  deactivate
fi

if [ $stage -le 4 ]; then
  echo "Expand"
  utils/slurm.pl --mem 4G JOB=1:$nj ${dir}/log/expand-numbers.JOB.log expand-numbers --word-symbol-table=$base_norm_model/baseLM_words.txt ark,t:$dir/split${nj}/cleantext_afterWordMapping.JOB.txt $base_norm_model/base_expand_to_words.fst $base_norm_model/base_expansionLM_${order}g.fst ark,t:$dir/split${nj}/text_expanded_${order}g.JOB.txt

fi

if [ $stage -le 5 ]; then

  echo "Insert words back"
  utils/slurm.pl --time 0-16 JOB=1:$nj ${dir}/log/re-insert-oov.JOB.log local/re-insert-oov.sh ${dir}/split${nj}/text_expanded_${order}g.JOB.txt ${dir}/split${nj}/mappedWords_jobJOB.txt
  
  echo "Check if all the speeches were expanded"
  join -1 1 -2 1 <(egrep "(^[0-9]{10} *$)|(rad[0-9T]+ *$)" ${dir}/split${nj}/text_expanded_${order}g.*.txt | sed 's/ *//g' | sort) <(sort ${dir}/split${nj}/cleantext_afterWordMapping.*.txt) > ${dir}/split${nj}/text_notexpanded_${order}g.txt
  # Ignore lines which were not expanded
  if [ $nj -eq 1 ]; then
    grep -vFf <(cut -d" " -f1 ${dir}/split${nj}/text_notexpanded_${order}g.txt) ${dir}/split${nj}/text_expanded_${order}g.*.wOOV.txt | sort -n > ${dir}/split${nj}/text_expanded_${order}g_wOOV.txt
  else
    grep -vFf <(cut -d" " -f1 ${dir}/split${nj}/text_notexpanded_${order}g.txt) ${dir}/split${nj}/text_expanded_${order}g.*.wOOV.txt | cut -d":" -f2- | sort -n > ${dir}/split${nj}/text_expanded_${order}g_wOOV.txt
  fi
  
  if [[ -s ${dir}/split${nj}/text_notexpanded_${order}g.txt ]]; then
    n=$(cat ${dir}/split${nj}/text_notexpanded_${order}g.txt | wc -l)
    echo $n" lines were empty after expansion\n"
    echo "they can be viewed in ${dir}/split${nj}/text_notexpanded_${order}g.txt"
    exit 1;
  else
    echo "All speeches were expanded :)"
    # If LM utterances then I remove the uttIDs
    if egrep -q "^[0-9]{10}" ${dir}/split${nj}/text_expanded_${order}g_wOOV.txt; then
      cut -d" " -f2- ${dir}/split${nj}/text_expanded_${order}g_wOOV.txt \
      > $dir/tmp && mv $dir/tmp ${dir}/split${nj}/text_expanded_${order}g_wOOV.txt
    fi
  fi  
fi

if [ $stage -le 6 ]; then

  if [ -e ${outfile} ] ; then
    # we don't want to overwrite old stuff, ask the user to delete it.
    echo "$0: ${outfile} already exists: "
    echo "Are you sure you want to proceed?"
    echo "It will overwrite the file"
    echo ""
    echo "  If so, please delete and then rerun this part"
    exit 1;
  else
    cp ${dir}/split${nj}/text_expanded_${order}g_wOOV.txt ${outfile}
  fi
fi

# Change back the slurm config file 
#sed -r -i 's:(command sbatch .*?) --nodelist=terra:\1:' conf/slurm.conf

exit 0;
