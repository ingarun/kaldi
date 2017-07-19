#!/bin/bash -eu

# Copyright 2017  Reykjavik University (Author: Inga Rún Helgadóttir)
# Apache 2.0

set -o pipefail

# Outdated. Compare with recognize.sh before using
# Comparing recognition results from two different types of recognizers.

speechfile=$1
speechname=$(basename "$speechfile")
extension="${speechname##*.}"
speechname="${speechname%.*}"

stage=-1

num_jobs=1

score=true

echo "$0 $@"  # Print the command line for logging

. ./cmd.sh
. ./path.sh
. ./utils/parse_options.sh

datadir=recognize/compare/$speechname
langdir=data/lang_cs
graphdir_normal=exp/tri3/graph_3g_cs_023pruned
graphdir_chain=exp/chain/tdnn_lstm_1e/graph_3g_cs_023pruned
normal=${datadir}_segm_hires/normal
chain=${datadir}_segm_hires/chain
decodedir_normal=${normal}/decode_3g_cs_023pruned
decodedir_chain=${chain}/decode_3g_cs_023pruned
rescoredir_normal=${normal}/decode_5g_cs
rescoredir_chain=${chain}/decode_5g_cs
oldLMdir=data/lang_3g_cs_023pruned
newLMdir=data/lang_5g_cs_const

mkdir -p ${datadir}
mkdir -p ${normal}
mkdir -p ${chain}

if [ $stage -le 0 ]; then

    echo "Set up a directory in the right format of Kaldi and extract features"
    local/prep_audiodata.sh $speechname $datadir
fi

if [ $stage -le 3 ]; then

    echo "Segment audio data"
    local/segment_audio.sh ${datadir} ${datadir}_segm
fi

if [ $stage -le 4 ]; then

    echo "Create high resolution MFCC features"
    utils/copy_data_dir.sh ${datadir}_segm ${datadir}_segm_hires
    steps/make_mfcc.sh \
	--nj $num_jobs --mfcc-config conf/mfcc_hires.conf \
        --cmd "$train_cmd" ${datadir}_segm_hires || exit 1;
    steps/compute_cmvn_stats.sh ${datadir}_segm_hires || exit 1;
    utils/fix_data_dir.sh ${datadir}_segm_hires
fi

if [ $stage -le 5 ]; then

    echo "Extracting iVectors"
    mkdir -p ${datadir}_segm_hires/ivectors_hires
    steps/online/nnet2/extract_ivectors_online.sh \
	--cmd "$train_cmd" --nj $num_jobs \
        ${datadir}_segm_hires exp/nnet3/extractor \
        ${datadir}_segm_hires/ivectors_hires || exit 1;
fi

if [ $stage -le 6 ]; then

    echo "Decoding"
    extra_left_context=40
    extra_right_context=0
    frames_per_chunk=20
    cp exp/nnet3/lstm_ld5/{final.mdl,final.ie.id,cmvn_opts} ${normal}
    #cp ${datadir}_segm_hires/ivectors_hires/final.ie.id ${datadir}_segm_hires
    (
	steps/nnet3/decode.sh \
	    --nj $num_jobs --cmd "$decode_cmd" \
	    --skip-scoring true \
	    --extra-left-context $extra_left_context  \
	    --extra-right-context $extra_right_context  \
	    --frames-per-chunk "$frames_per_chunk" \
	    --online-ivector-dir ${datadir}_segm_hires/ivectors_hires \
	    $graphdir_normal ${datadir}_segm_hires ${decodedir_normal} || exit 1; 

	steps/lmrescore_const_arpa.sh \
            --cmd "$decode_cmd" --skip-scoring true \
            ${oldLMdir} ${newLMdir} ${datadir}_segm_hires \
            ${decodedir_normal} ${rescoredir_normal} || exit 1;
    ) &
    
    rm ${datadir}_segm_hires/.error 2>/dev/null || true

    frames_per_chunk_primary=140
    extra_left_context=50
    extra_right_context=0
    cp exp/chain/tdnn_lstm_1e/{final.mdl,final.ie.id,cmvn_opts,frame_subsampling_factor} ${chain}

    steps/nnet3/decode.sh \
	--acwt 1.0 --post-decode-acwt 10.0 \
	--nj $num_jobs --cmd "$decode_cmd" \
	--skip-scoring true \
	--extra-left-context $extra_left_context  \
	--extra-right-context $extra_right_context  \
	--extra-left-context-initial 0 \
	--extra-right-context-final 0 \
	--frames-per-chunk "$frames_per_chunk_primary" \
	--online-ivector-dir ${datadir}_segm_hires/ivectors_hires \
	$graphdir_chain ${datadir}_segm_hires ${decodedir_chain} || exit 1;
    
    steps/lmrescore_const_arpa.sh \
	--cmd "$decode_cmd" --skip-scoring true \
	${oldLMdir} ${newLMdir} ${datadir}_segm_hires \
	${decodedir_chain} ${rescoredir_chain} || exit 1;
    
    wait
    if [ -f ${datadir}_segm_hires/.error ]; then
	echo "$0: something went wrong in decoding"
	exit 1
    fi
fi


if [ $stage -le 7 ]; then

    echo "Extract the transcript hypothesis from the Kaldi lattice"
    for d in ${rescoredir_normal} ${rescoredir_chain}; do
	
    lattice-best-path \
        --lm-scale=9 \
        --word-symbol-table=${langdir}/words.txt \
        "ark:zcat ${d}/lat.1.gz |" ark,t:- &> ${d}/extract_transcript.log

    # Extract the best path text (tac - concatenate and print files in reverse)
    tac ${d}/extract_transcript.log | grep -e '^[^ ]\+rad' | sort -u -t" " -k1,1 > ${d}/transcript.txt

    # Remove utterance IDs
    perl -pe 's/[^ ]+rad[^ ]+//g' ${d}/transcript.txt | tr "\n" " " | sed -e "s/[[:space:]]\+/ /g" > ${d}/transcript_noID.txt
    done
fi

if [ $stage -le 8 ]; then

    echo "Align the two transcripts for comparison"
    align-text ark,t:${rescoredir_normal}/transcript.txt ark,t:${rescoredir_chain}/transcript.txt ark,t:${rescoredir_chain}/align-chain-normal.txt
fi

if $score ; then

    echo "Estimate the WER"
    local/score_recognize.sh --cmd "$decode_cmd" $speechname ${langdir} ${rescoredir_normal} &
    local/score_recognize.sh --cmd "$decode_cmd" $speechname ${langdir} ${rescoredir_chain} &

fi

rm -r ${datadir} ${datadir}_segm
