#!/bin/bash -eu

# Copyright 2017  Reykjavik University (Author: Inga Rún Helgadóttir)
# Apache 2.0

set -o pipefail

textfile=$1
wordfile=$2
textfile_wOOV="${textfile%.*}.wOOV.txt"

tmp=$(mktemp -d)
cleanup () {
    rm -rf "$tmp"
}
trap cleanup EXIT

IFS=$'\n'
#cp ${textfile} ${textfile_wOOV}
for l in $(cat ${wordfile}); do
    uttID=$(echo $l | cut -d" " -f1)
    num_words=$(echo $l | wc -w)
    grep $uttID ${textfile} > $tmp/expanded_line
    for i in $(seq 2 $num_words); do
        w=$(echo $l | cut -d" " -f$i)
        sed -i "s:<word>:$w:" $tmp/expanded_line
    done
    #newline=$(cat $tmp/expanded_line)
    #sed -i -r "s:$uttID.*:$newline:" ${textfile_wOOV}
    cat $tmp/expanded_line >> ${textfile_wOOV}
done

textfile_base=${textfile##*/}
comm -13 <(cut -d" " -f1 ${textfile_wOOV} | sort -u) <(cut -d" " -f1 ${textfile} | sort -u) > ids_only_in_${textfile_base%.*}.tmp
join -j1 ids_only_in_${textfile_base%.*}.tmp ${textfile} >> ${textfile_wOOV}
sort -u ${textfile_wOOV} > tmp && mv tmp ${textfile_wOOV}
   
exit 0;
