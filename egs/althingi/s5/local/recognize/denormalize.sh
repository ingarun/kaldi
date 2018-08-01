#!/bin/bash -e

set -o pipefail

# Copyright 2017  Reykjavik University (Author: Inga Rún Helgadóttir)
# Apache 2.0

# Denormalize speech recognition transcript

# local/recognize/denormalize.sh <text-input> <denormalized-text-output>

. ./path.sh
. ./cmd.sh
. ./utils/parse_options.sh
. ./local/utils.sh
. ./local/array.sh

if [ $# != 3 ]; then
  echo "This scripts handles the denormalization of an ASR transcript"
  echo "Usually called from the transcription script, recognize.sh"
  echo ""
  echo "Usage: $0 <model-dir> <ASR-transcript> <out-file>"
  echo " e.g.: $0 ~/models/latest output/radXXX/ASRtranscript.txt output/radXXX/radXXX.txt"
  exit 1;
fi

bundle=$1
ifile=$2
ofile=$3
dir=$(dirname $(readlink -f $ofile))
intermediate=$dir/intermediate
mkdir -p $intermediate

utf8syms=$bundle/utf8.syms
normdir=$bundle/text_norm
personal_names=$bundle/latest/ambiguous_personal_names
punctuation_model=$bundle/punctuation_model
paragraph_model=$bundle/paragraph_model

for f in $ifile $utf8syms $normdir/ABBR_AND_DENORM.fst \
  $normdir/INS_PERIODS.fst $punctuation_model $paragraph_model; do
  [ ! -f $f ] && echo "$0: expected $f to exist" && exit 1;
done  

echo "Abbreviate"
# Numbers are not in the words.txt file. Hence I can't compose with an utf8-to-words.fst file. Also, remove uttIDs
fststringcompile ark:$ifile ark:- \
  | fsttablecompose --match-side=left ark,t:- $normdir/ABBR_AND_DENORM.fst ark:- \
  | fsts-to-transcripts ark:- ark,t:- \
  | int2sym.pl -f 2- ${utf8syms} | cut -d" " -f2- \
  | sed -re 's: ::g' -e 's:0x0020: :g' \
  | tr "\n" " " | sed -r "s/ +/ /g" \
  > ${intermediate}/thrax_out.tmp || error 8 ${error_array[8]};

# Need to activate the conda environment for the punctuation and paragraph models
source activate thenv || error 11 ${error_array[11]};

echo "Extract the numbers before punctuation"
python punctuator/local/saving_numbers.py \
  ${intermediate}/thrax_out.tmp \
  ${intermediate}/punctuator_in.tmp \
  ${intermediate}/numlist.tmp || exit 1;

echo "Punctuate"
cat ${intermediate}/punctuator_in.tmp \
  | THEANO_FLAGS='device=cpu' python punctuator/punctuator.py \
    $punctuation_model ${intermediate}/punctuator_out.tmp \
  || error 9 ${error_array[9]};
wait

echo "Re-insert the numbers"
if [ -s  ${intermediate}/numlist.tmp ]; then
  python punctuator/local/re-inserting-numbers.py \
    ${intermediate}/punctuator_out.tmp \
    ${intermediate}/numlist.tmp \
    ${intermediate}/punctuator_out_wNumbers.tmp || exit 1;
else
    cp ${intermediate}/punctuator_out.tmp ${intermediate}/punctuator_out_wNumbers.tmp || exit 1;
fi

echo "Convert punctuation tokens back to actual punctuations and capitalize"
python punctuator/convert_to_readable.py \
  ${intermediate}/punctuator_out_wNumbers.tmp \
  ${intermediate}/punctuator_out_wPuncts.tmp || exit 1;

echo "Insert periods into abbreviations and insert period at the end of the speech"
fststringcompile ark:"sed 's:.*:1 &:' ${intermediate}/punctuator_out_wPuncts.tmp |" ark:- \
  | fsttablecompose --match-side=left ark,t:- $normdir/INSERT_PERIODS.fst ark:- \
  | fsts-to-transcripts ark:- ark,t:- | int2sym.pl -f 2- ${utf8syms} \
  | cut -d" " -f2- | sed -re 's: ::g' -e 's:0x0020: :g' \
  | tr "\n" " " | sed -re "s/ +/ /g" -e 's:\s*$:.:' \
  > ${intermediate}/punctuator_out_wPeriods.tmp || error 8 ${error_array[8]};

echo "Insert paragraph breaks using a paragraph model"
cat ${intermediate}/punctuator_out_wPeriods.tmp \
  | THEANO_FLAGS='device=cpu' python paragraph/paragrapher.py \
    $paragraph_model ${intermediate}/paragraphed_tokens.tmp \
  || error 10 ${error_array[10]};

python paragraph/convert_to_readable.py \
  ${intermediate}/paragraphed_tokens.tmp \
  $ofile 1 || exit 1;

#sed -r 's:\. ([^ ]+ forseti\.):\.\n\1:g' ${intermediate}/paragraphed_tokens.tmp > $ofile

# # Maybe fix the casing of prefixes?
# cat /data/althingi/lists/forskeyti.txt /data/althingi/lists/forskeyti.txt | sort | awk 'ORS=NR%2?":":"\n"' | sed -re 's/^.*/s:&/' -e 's/$/:gI/g' > prefix_sed_pattern.tmp

# # Fix the casing of known named entities
# /bin/sed -f ${intermediate}/ner_sed_pattern.tmp file > file_out

source deactivate

exit 0;
