#!/bin/bash -u
#
# Prepare training lang dir, given a data dir and Framburðarorðabókin
#
# Copyright: 2015 Robert Kjaran
#            2016 Inga Run
#
# TODO(rkjaran): G2P using Phonetisaurus and RnnLMG2P

. local/utils.sh

tmpdir=
cleanup=false
vocab=
. utils/parse_options.sh
if [ $# -ne 4 ]; then
    echo "Usage: $0 <frob-tsv> <tmp-dir> <dest-dir>" >&2
    echo "Eg. $0 data/local/frob.txt data/local/dict data/lang" >&2
    exit 1;
fi

frob=$1;shift
dictdir=$1; shift
langdir=$1; shift

# check prereqs
[ -f "$frob" ] || error "Can't access $frob"

mkdir -p $langdir && mkdir -p $dictdir || error "Can't create dest dirs"

echo "Converting to lexicon.txt"
cat $frob <(echo "<unk> oov") \
    > $dictdir/lexicon.txt || error "Could not create $dictdir/lexicon.txt"

# note: LC_ALL=C needed for sort uniq because of uniqs weird behaviour with these unicode chars
cut -f2- $frob \
    | tr ' ' '\n' | LC_ALL=C sort -u > $dictdir/nonsilence_phones.txt
# stress marked phones grouped together with its stressless counterpart
join -t '' \
     <(grep : $dictdir/nonsilence_phones.txt) \
     <(grep -v : $dictdir/nonsilence_phones.txt | awk '{print $1 ":"}' | sort) \
    | awk '{s=$1; sub(/:/, ""); print $1 " " s }' \
     > $dictdir/extra_questions.txt

for w in sil oov; do echo $w; done > $dictdir/silence_phones.txt
echo "sil" > $dictdir/optional_silence.txt

utils/prepare_lang.sh \
    $dictdir "<unk>" data/local/lang $langdir

utils/validate_lang.pl $langdir || error "lang dir invalid"

exit 0
