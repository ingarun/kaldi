#!/bin/bash -eux
set -o pipefail
# Idea from: Sproat, R. (2010). Lightly supervised learning of text normalization: Russian number names.

# Run from one directory up

# TODO: map words not in our chosen word symbol table to <unk> (which is in the symtab, btw)
# TODO: (in grammar) try to limit false positives, such as "eins og -> 1 og"
# TODO: Remove all lines in ARPA n-gram which contain numerals. The LM should only be for expanded nums

# NOTE! I add all the althingi data to the language model too make sure everything prints out. It would
# probably be way better to map to <unk> and then try to reverse it later.

nj=25
stage=2
corpus=/data/leipzig/isl_sentences_10M.txt
textnorm=text_norm
dir=text_norm/text
utf8syms=text_norm/utf8.syms
althdir=data/all

run_tests=false

. ./cmd.sh
. ./path.sh
. utils/parse_options.sh

tmp=$(mktemp -d)
cleanup () {
    rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p $dir

# Convert text file to a Kaldi table (ark).
# The archive format is:
# <key1> <object1> <newline> <key2> <object2> <newline> ...
if [ $stage -le 0 ]; then
    # Each text lowercased and given an text_id,
    # which is just the 10-zero padded line number
    awk '{printf("%010d %s\n", NR, tolower($0))}' $corpus \
    > ${dir}/texts.txt
fi

if [ $stage -le 1 ]; then
    
    echo "Clean the text a little bit"

    # Rewrite some and remove other punctuations. I couldn't exape
    # the single quote so use a hexadecimal escape

    # 1) Remove punctuations which is safe to remove
    # 7) Remove final period and periods and commas after letters,
    # 10) Swap "-" and "/" out for a space when sandwitched between words, f.ex. "suður-kórea" and "svart/hvítt",
    # 11) Rewrite en dash (x96) to " til ", if sandwitched between words or numbers,
    # 13) Remove remaining punctuations,
    # 14) Change & to "og" and change spaces to one between words.
    utils/slurm.pl \
        ${dir}/log/puncts_removal.log \
        perl -pe 's/\?|!|\+|\*|=|…|\[|\]|\.\.+|,,|;|\"|“|„|”|‘|’|´|\Q`\E|¨|¬|\)|\(|«|»|›|>|<|~|_|→|\x27|#|•|·|ˆ|//g' ${dir}/texts.txt \
	| perl -pe 's/([^0-9])[\.\,](\s+|$)/$1$2/g' \
	| perl -pe 's/([a-záðéíóúýþæö%0-9])[-\/]([a-záðéíóúýþæö])/$1 $2/g' \
	| perl -pe 's/([0-9a-záðéíóúýþæö])–([0-9a-záðéíóúýþæö])/$1 til $2/g' \
	| perl -pe 's/—|–|-|:|//g' \
	| sed 's/&/og/g' | tr -s " " > ${dir}/text_no_puncts.txt

    # Sort the vocabulary based on frequency count
    cut -d' ' -f2- < ${dir}/text_no_puncts.txt \
        | tr ' ' '\n' \
        | egrep -v '^\s*$' > $tmp/words \
        && sort --parallel=8 $tmp/words \
            | uniq -c > $tmp/words.sorted \
        && sort -k1 -n --parallel=$[nj>8 ? 8 : nj] \
	    $tmp/words.sorted > ${dir}/words.cnt
    
fi

if [ $stage -le 2 ]; then
    # We select a subset of the vocabulary, every token occurring 30
    # times or more. This removes a lot of non-sense tokens.
    # But there is still a bunch of crap in there
    awk '$2 ~ /[[:print:]]/ { if($1 > 29) print $2 }' \
        ${dir}/words.cnt | LC_ALL=C sort -u > ${dir}/wordlist30.txt

    # Get the althingi vocabulary
    cut -d" " -f2- ${althdir}/text_bb_SpellingFixed.txt | tr " " "\n" | grep -v "^\s*$" | LC_ALL=C sort -u > ${dir}/words_althingi.txt

    # Get a list of words solely in the althingi data and add it to wordlist30.txt
    comm -23 <(sort ${dir}/words_althingi.txt) <(sort ${dir}/wordlist30.txt) > ${dir}/vocab_alth_only.txt
    cat ${dir}/wordlist30.txt > ${dir}/wordlist30_plusAlthingi.txt
    cat ${dir}/vocab_alth_only.txt >> ${dir}/wordlist30_plusAlthingi.txt
    
    # Here I add the expanded abbreviations that were filtered out and althingi-only-vocab.
    abbr_expanded=$(cut -f2 ~/kaldi/egs/althingi/s5/text_norm/lex/abbr_lexicon.txt | cut -d" " -f1)
    for abbr in $abbr_expanded
    do
	grep -q "\b${abbr}\b" ${dir}/wordlist30_plusAlthingi.txt || echo -e ${abbr} >> ${dir}/wordlist30_plusAlthingi.txt
    done

    # Add expanded numbers to the list
    cut -f2 ${textnorm}/lex/ordinals_*?_lexicon.txt >> ${dir}/wordlist30_plusAlthingi.txt
    cut -f2 ${textnorm}/lex/units_lexicon.txt >> ${dir}/wordlist30_plusAlthingi.txt

    
    # Make a word symbol table. Code from prepare_lang.sh
    cat ${dir}/wordlist30_plusAlthingi.txt | LC_ALL=C sort | uniq  | awk '
    BEGIN {
      print "<eps> 0";
    }
    {
      if ($1 == "<s>") {
        print "<s> is in the vocabulary!" | "cat 1>&2"
        exit 1;
      }
      if ($1 == "</s>") {
        print "</s> is in the vocabulary!" | "cat 1>&2"
        exit 1;
      }
      printf("%s %d\n", $1, NR);
    }
    END {
      printf("<unk> %d\n", NR+1);
    }' > $dir/words30.txt

    # Replace OOVs with <unk>
    cat ${dir}/text_no_puncts.txt \
        | utils/sym2int.pl --map-oov "<unk>" -f 2- ${dir}/words30.txt \
        | utils/int2sym.pl -f 2- ${dir}/words30.txt > ${dir}/text_no_oovs.txt

    # We want to process it in parallel. NOTE! One time split_scp.pl complained about $out_scps!
    mkdir -p ${dir}/split$nj/
    out_scps=$(for j in `seq 1 $nj`; do printf "${dir}/split%s/text_no_oovs.%s.txt " $nj $j; done)
    utils/split_scp.pl ${dir}/text_no_oovs.txt $out_scps
    
fi

if [ $stage -le 3 ]; then
    # Compile the lines to linear FSTs with utf8 as the token type
    utils/slurm.pl --mem 2G JOB=1:$nj ${dir}/log/compile_strings.JOB.log fststringcompile ark:${dir}/split$nj/text_no_oovs.JOB.txt ark:"| gzip -c > ${dir}/text_fsts.JOB.ark.gz" &
    
fi

if [ $stage -le 4 ]; then
    # We need a FST to map from utf8 tokens to words in the words symbol table.
    # f1=word, f2-=utf8_tokens (0x0020 always ends a utf8_token seq)
    utils/slurm.pl \
        ${dir}/log/words30_to_utf8.log \
        awk '$2 != 0 {printf "%s %s \n", $1, $1}' \< ${dir}/words30.txt \
        \| fststringcompile ark:- ark:- \
        \| fsts-to-transcripts ark:- ark,t:- \
        \| int2sym.pl -f 2- ${utf8syms} \> ${dir}/words30_to_utf8.txt
 
    utils/slurm.pl \
        ${dir}/log/utf8_to_words30.log \
        utils/make_lexicon_fst.pl ${dir}/words30_to_utf8.txt \
        \| fstcompile --isymbols=${utf8syms} --osymbols=${dir}/words30.txt --keep_{i,o}symbols=false \
        \| fstarcsort --sort_type=ilabel \
        \| fstclosure --closure_plus     \
        \| fstrmepsilon \| fstminimize   \
        \| fstarcsort --sort_type=ilabel \> ${dir}/utf8_to_words30_plus.fst

 
    # EXPAND_UTT is an obligatory rewrite rule that accepts anything as input
    # and expands what can be expanded. Note! It does not accept capital letters.
    # Create the fst that works with expand-numbers, using words30.txt as
    # symbol table. NOTE! I changed map_type from rmweight to arc_sum to fix weight problem
    utils/slurm.pl \
        ${dir}/log/expand_to_words30.log \
        fstcompose ${textnorm}/EXPAND_UTT.fst ${dir}/utf8_to_words30_plus.fst \
        \| fstrmepsilon \| fstmap --map_type=arc_sum \
        \| fstarcsort --sort_type=ilabel \> ${textnorm}/expand_to_words30.fst &

    # # Test doing this in smaller pieces. NOTE! Did not change a thing!
    # utils/slurm.pl \
    #     ${dir}/log/expand_abbr.log \
    #     fstcompose ${textnorm}/EXPAND_ABBRplus.fst ${dir}/utf8_to_words30_plus.fst \
    #     \| fstrmepsilon \| fstmap --map_type=rmweight \
    #     \| fstarcsort --sort_type=ilabel \> ${textnorm}/expand_abbr.fst &
fi

if [ $stage -le 5 ]; then	    
    # we need to wait for the text_fsts from stage 3 to be ready
    wait
    # Find out which lines can be rewritten. All other lines are filtered out.
    mkdir -p ${dir}/abbreviated_fsts
    utils/slurm.pl JOB=1:$nj ${dir}/log/abbreviated.JOB.log fsttablecompose --match-side=left ark,s,cs:"gunzip -c ${dir}/text_fsts.JOB.ark.gz |" ${textnorm}/ABBREVIATE.fst ark:- \| fsttablefilter --empty=true ark,s,cs:- ark,scp:${dir}/abbreviated_fsts/abbreviated.JOB.ark,${dir}/abbreviated_fsts/abbreviated.JOB.scp
fi


if [ $stage -le 6 ]; then
    if [ -f ${dir}/numbertext.txt.gz ]; then
        mkdir -p ${dir}/.backup
        mv ${dir}/{,.backup/}numbertext.txt.gz
    fi

    # Here the lines in text that are rewriteable are selected, based on key.
    IFS=$' \t\n'
    sub_nnrewrites=$(for j in `seq 1 $nj`; do printf "${dir}/abbreviated_fsts/abbreviated.%s.scp " $j; done)
    # cat $sub_nnrewrites \
    #     | awk '{print $1}' \
    #     | sort -k1 \
    #     | join - ${dir}/text_no_oovs.txt \ 
    #     | cut -d ' ' -f2- \
    #     | gzip -c > ${dir}/numbertext.txt.gz
    cat $sub_nnrewrites | awk '{print $1}' | sort -k1 | join - ${dir}/text_no_oovs.txt | cut -d' ' -f2- > ${dir}/numbertext.txt

    # Add the Althingi data to numbertext to make sure everything will be printed out after expansion.
    cut -d" " -f2- ${althdir}/text_bb_SpellingFixed.txt >> ${dir}/numbertext.txt
    gzip -c ${dir}/numbertext.txt > ${dir}/numbertext.txt.gz
    rm ${dir}/numbertext.txt

    # Fix spelling errors on LC_ALL=C sort ${althdir}/text_exp2_bb.txt | tail -n18 > tail18_text_unexpanded.txt
    #cut -d" " -f2- ${althdir}/text | head -n980 >> ${dir}/numbertext.txt
    # cut -d" " -f2- ${althdir}/tail18_text_unexpanded.txt >> ${dir}/numbertext.txt
fi

if [ $stage -le 7 ]; then
    for n in 3 5; do
        echo "Building ${n}-gram"
        if [ -f ${dir}/numbertext_${n}g.arpa.gz ]; then
            mkdir -p ${dir}/.backup
            mv ${dir}/{,.backup/}numbertext_${n}g.arpa.gz
        fi

        # KenLM is superior to every other LM toolkit (https://github.com/kpu/kenlm/).
        # multi-threaded and designed for efficient estimation of giga-LMs
        /opt/kenlm/build/bin/lmplz \
	    --skip_symbols \
            -o ${n} -S 70% --prune 0 0 1 \
            --text ${dir}/numbertext.txt.gz \
            --limit_vocab_file <(cut -d " " -f1 ${dir}/words30.txt | egrep -v "<eps>|<unk>") \
            | gzip -c > ${dir}/numbertext_${n}g.arpa.gz
    done

    # Try out a bigram LM
    if [ -f ${dir}/numbertext_2g.arpa.gz ]; then
        mv ${dir}/{,.backup/}numbertext_2g.arpa.gz
    fi
    /opt/kenlm/build/bin/lmplz \
	--skip_symbols \
        -o 2 -S 70% --prune 0 1 \
            --text ${dir}/numbertext.txt.gz \
            --limit_vocab_file <(cut -d " " -f1 ${dir}/words30.txt | egrep -v "<eps>|<unk>") \
            | gzip -c > ${dir}/numbertext_2g.arpa.gz
    
fi

if [ $stage -le 8 ]; then
    # Get the fst language model. Obtained using the rewritable sentences.
    for n in 3 5; do
        if [ -f ${dir}/numbertext_${n}g.fst ]; then
            mkdir -p ${dir}/.backup
            mv ${dir}/{,.backup/}numbertext_${n}g.fst
        fi

        arpa2fst "zcat ${dir}/numbertext_${n}g.arpa.gz |" - \
            | fstprint \
            | utils/s2eps.pl \
            | fstcompile --{i,o}symbols=${dir}/words30.txt --keep_{i,o}symbols=false \
            | fstarcsort --sort_type=ilabel \
                         > ${dir}/numbertext_${n}g.fst
    done

    # A bigram LM
    if [ -f ${dir}/numbertext_2g.fst ]; then
            mkdir -p ${dir}/.backup
            mv ${dir}/{,.backup/}numbertext_2g.fst
        fi
    arpa2fst "zcat ${dir}/numbertext_2g.arpa.gz |" - \
            | fstprint \
            | utils/s2eps.pl \
            | fstcompile --{i,o}symbols=${dir}/words30.txt --keep_{i,o}symbols=false \
            | fstarcsort --sort_type=ilabel \
                         > ${dir}/numbertext_2g.fst
    
fi

if [ $stage -le 9 ] && $run_tests; then
    # Let's test the training set, or a subset.

    # Combine, shuffle and subset
    sub_nnrewrites=$(for j in `seq 1 $nj`; do printf "${dir}/abbreviated_fsts/abbreviated.%s.scp " $j; done)
    all_cnt=$(cat $sub_nnrewrites | wc -l)
    test_cnt=$[all_cnt * 5 / 1000]
    cat $sub_nnrewrites | shuf -n $test_cnt | LC_ALL=C sort -k1b,1 > ${dir}/abbreviated_test.scp

    utils/split_scp.pl ${dir}/abbreviated_test.scp ${dir}/abbreviated_test.{1..8}.scp

    for n in 3 5; do
        # these narrowed lines should've had all OOVs mapped to <unk>
        # (so we can do the utf8->words30 mapping, without completely
        # skipping lines with OOVs)
        utils/slurm.pl JOB=1:8 ${dir}/log/expand_test${n}g.JOB.log fsttablecompose --match-side=left scp:${dir}/abbreviated_test.JOB.scp ${dir}/expand_to_words30.fst ark:- \| fsttablecompose --match-side=left ark:- ${dir}/numbertext_${n}g.fst ark:- \| fsts-to-transcripts ark:- ark,t:"| utils/int2sym.pl -f 2- ${dir}/words30.txt > ${dir}/expand_text_test_${n}g.JOB.txt"
    done

    wait
fi

# Extremely messy example usage:
# $ fststringcompile ark:<(echo a " hér eru 852 konur . einnig var sagt frá 852 konum sem geta af sér 852 börn . ") ark:- | fsttablecompose ark,p:- "fstsymbols --clear_isymbols --clear_osymbols ${textnorm}/ABBREVIATE.fst | fstinvert |" ark:- | fsttablecompose ark:- ${dir}/utf8_to_words30_plus.fst ark:- | sed 's/a //' | fstproject --project_output | fstintersect - ${dir}/numbertext_2g.fst | fstshortestpath | fstrmepsilon  | fsts-to-transcripts scp:"echo a -|" ark,t:- | int2sym.pl -f 2- ${dir}/words30.txt | cut -d' ' -f2-
# Returns: hér eru átta hundruð fimmtíu og tvær konur . einnig var sagt frá átta hundruð fimmtíu og tveimur konum sem geta af sér átta hundruð fimmtíu og tvö börn .

