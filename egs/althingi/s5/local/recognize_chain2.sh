#!/bin/bash

# 2017 - Inga
# Decode audio. Bla bla
# Usage: $0 <audiofile> <metadata>
# Example (if want to save the time info as well):
# { time local/recognize_chain2.sh data/local/corpus/audio/rad20160309T151154.flac data/local/corpus/metadata.csv; } &> recognize/chain/rad20160309T151154.log

set -e

# configs
stage=-1
num_jobs=1
score=true

echo "$0 $@"  # Print the command line for logging

. ./cmd.sh
. ./path.sh
. ./utils/parse_options.sh

speechfile=$1
speechname=$(basename "$speechfile")
extension="${speechname##*.}"
speechname="${speechname%.*}"

speakerfile=$2  # A meta file containing the name of the speaker

# Dirs used #
# Already existing
langdir=data/lang_cs
graphdir=exp/chain/tdnn_lstm_1e_sp/graph_3g_cs_023pruned
oldLMdir=data/lang_3g_cs_023pruned
newLMdir=data/lang_5g_cs_const
# Created
datadir=recognize/chain/$speechname
mkdir -p ${datadir}
decodedir=${datadir}_segm_hires/decode_3g_cs_023pruned
rescoredir=${datadir}_segm_hires/decode_5g_cs

if [ $stage -le 0 ]; then

    echo "Set up a directory in the right format of Kaldi and extract features"
    local/prep_audiodata_fromName2.sh $speechname $speakerfile $datadir
    spkID=$(cut -d" " -f1 $datadir/spk2utt)
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
        ${datadir}_segm_hires exp/chain/extractor \
        ${datadir}_segm_hires/ivectors_hires || exit 1;
fi

if [ $stage -le 6 ]; then
    rm ${datadir}_segm_hires/.error 2>/dev/null || true

    frames_per_chunk=140,100,160
    frames_per_chunk_primary=$(echo $frames_per_chunk | cut -d, -f1)
    extra_left_context=50
    extra_right_context=0
    cp exp/chain/tdnn_lstm_1e_sp/{final.mdl,final.ie.id,cmvn_opts,frame_subsampling_factor} ${datadir}_segm_hires

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
	$graphdir ${datadir}_segm_hires ${decodedir} || exit 1;
    
    steps/lmrescore_const_arpa.sh --cmd "$decode_cmd" --skip-scoring true \
	${oldLMdir} ${newLMdir} ${datadir}_segm_hires \
	${decodedir} ${rescoredir} || exit 1;
    
    wait
fi


if [ $stage -le 7 ]; then

    echo "Extract the transcript hypothesis from the Kaldi lattice"
    lattice-best-path \
        --lm-scale=10 \
        --word-symbol-table=${langdir}/words.txt \
        "ark:zcat ${rescoredir}/lat.1.gz |" ark,t:- &> ${rescoredir}/extract_transcript.log

    # Extract the best path text (tac - concatenate and print files in reverse)
    tac ${rescoredir}/extract_transcript.log | grep -e '^[^ ]\+rad' | sort -u -t" " -k1,1 > ${rescoredir}/transcript.txt

    # Remove utterance IDs
    perl -pe 's/[^ ]+rad[^ ]+//g' ${rescoredir}/transcript.txt | tr "\n" " " | sed -e "s/[[:space:]]\+/ /g" > ${rescoredir}/transcript_noID.txt
fi

if [ $stage -le 8 ]; then

    echo "Denormalize the transcript"
    local/denormalize.sh \
        ${rescoredir}/transcript_noID.txt \
        ${rescoredir}/${spkID}_${speechname}_transcript.txt
    rm ${rescoredir}/*.tmp
fi

if [ $score = true ] ; then

    echo "Estimate the WER"
    # NOTE! Correct for the mismatch in the beginning and end of recordings.
    local/score_recognize.sh --cmd "$decode_cmd" $speechname ${langdir} ${rescoredir}
fi

rm -r ${datadir} ${datadir}_segm
