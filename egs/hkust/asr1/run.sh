#!/bin/bash

# Copyright 2017 Johns Hopkins University (Shinji Watanabe)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)

. ./path.sh
. ./cmd.sh

# general configuration
stage=0        # start from 0 if you need to start from data preparation
gpu=-1         # use 0 when using GPU on slurm/grid engine, otherwise -1
debugmode=1
dumpdir=dump   # directory to dump full features
N=0            # number of minibatches to be used (mainly for debugging). "0" uses all minibatches.
verbose=0      # verbose option

# feature configuration
do_delta=false # true when using CNN

# network archtecture
# encoder related
etype=vggblstmp     # encoder architecture type
elayers=4
eunits=320
eprojs=320
subsample=1_2_2_1_1 # skip every n frame from input to nth layers
# decoder related
dlayers=1
dunits=300
# attention related
atype=location
aconv_chans=10
aconv_filts=100

# hybrid CTC/attention
mtlalpha=0.5

# minibatch related
batchsize=30
maxlen_in=800  # if input length  > maxlen_in, batchsize is automatically reduced
maxlen_out=150 # if output length > maxlen_out, batchsize is automatically reduced

# optimization related
opt=adadelta
epochs=15

# decoding parameter
beam_size=20
penalty=0
maxlenratio=0.8
minlenratio=0.0
recog_model=acc.best # set a model to be used for decoding: 'acc.best' or 'loss.best'

# data
hkust1=/export/corpora/LDC/LDC2005S15/
hkust2=/export/corpora/LDC/LDC2005T32/

# exp tag
tag="" # tag for managing experiments.

. utils/parse_options.sh || exit 1;

. ./path.sh 
. ./cmd.sh 

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

train_set=train_nodup_sp
train_dev=train_dev
recog_set="dev train_dev"

if [ ${stage} -le 0 ]; then
    ### Task dependent. You have to make data the following preparation part by yourself.
    ### But you can utilize Kaldi recipes in most cases
    echo "stage 0: Data preparation"
    local/hkust_data_prep.sh ${hkust1} ${hkust2}
    local/hkust_format_data.sh
    # upsample audio from 8k to 16k to make a recipe consistent with others
    for x in train dev; do
        sed -i.bak -e "s/$/ sox -R -t wav - -t wav - rate 16000 dither | /" data/${x}/wav.scp
    done
    # remove space in text
    for x in train dev; do
        cp data/${x}/text data/${x}/text.org
        paste -d " " <(cut -f 1 -d" " data/${x}/text.org) <(cut -f 2- -d" " data/${x}/text.org | tr -d " ") \
            > data/${x}/text
        rm data/${x}/text.org
    done
fi

feat_tr_dir=${dumpdir}/${train_set}/delta${do_delta}; mkdir -p ${feat_tr_dir}
feat_dt_dir=${dumpdir}/${train_dev}/delta${do_delta}; mkdir -p ${feat_dt_dir}
if [ ${stage} -le 1 ]; then
    ### Task dependent. You have to design training and dev sets by yourself.
    ### But you can utilize Kaldi recipes in most cases
    echo "stage 1: Feature Generation"
    fbankdir=fbank
    # Generate the fbank features; by default 80-dimensional fbanks with pitch on each frame
    steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 32 data/train exp/make_fbank/train ${fbankdir}
    steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 10 data/dev exp/make_fbank/dev ${fbankdir}

    # make a dev set
    utils/subset_data_dir.sh --first data/train 4000 data/${train_dev}
    n=$[`cat data/train/segments | wc -l` - 4000]
    utils/subset_data_dir.sh --last data/train $n data/train_nodev

    # make a training set
    utils/data/remove_dup_utts.sh 300 data/train_nodev data/train_nodup

    # speed-perturbed
    utils/perturb_data_dir_speed.sh 0.9 data/train_nodup data/temp1
    utils/perturb_data_dir_speed.sh 1.0 data/train_nodup data/temp2
    utils/perturb_data_dir_speed.sh 1.1 data/train_nodup data/temp3
    utils/combine_data.sh --extra-files utt2uniq data/${train_set} data/temp1 data/temp2 data/temp3
    rm -r data/temp1 data/temp2 data/temp3
    steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 32 data/${train_set} exp/make_fbank/${train_set} ${fbankdir}

    # compute global CMVN
    compute-cmvn-stats scp:data/${train_set}/feats.scp data/${train_set}/cmvn.ark

    # dump features for training
    dump.sh --cmd "$train_cmd" --nj 32 --do_delta $do_delta \
        data/${train_set}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/train ${feat_tr_dir}
    dump.sh --cmd "$train_cmd" --nj 10 --do_delta $do_delta \
        data/${train_dev}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/dev ${feat_dt_dir}
fi

dict=data/lang_1char/${train_set}_units.txt
echo "dictionary: ${dict}"
if [ ${stage} -le 2 ]; then
    ### Task dependent. You have to check non-linguistic symbols used in the corpus.
    echo "stage 2: Dictionary and Json Data Preparation"
    mkdir -p data/lang_1char/

    echo "make a non-linguistic symbol list"
    nlsyms=data/lang_1char/non_lang_syms.txt
    cut -f 2- data/${train_set}/text | grep -o -P '\[.*?\]' | sort | uniq > ${nlsyms}
    cat ${nlsyms}

    echo "make a dictionary"
    echo "<unk> 1" > ${dict} # <unk> must be 1, 0 will be used for "blank" in CTC
    text2token.py -s 1 -n 1 -l ${nlsyms} data/${train_set}/text | cut -f 2- -d" " | tr " " "\n" \
	| sort | uniq | grep -v -e '^\s*$' | awk '{print $0 " " NR+1}' >> ${dict}
    wc -l ${dict}

    echo "make json files"
    data2json.sh --feat ${feat_tr_dir}/feats.scp --nlsyms ${nlsyms} \
		 data/${train_set} ${dict} > ${feat_tr_dir}/data.json
    data2json.sh --feat ${feat_dt_dir}/feats.scp --nlsyms ${nlsyms} \
		 data/${train_dev} ${dict} > ${feat_dt_dir}/data.json
fi

if [ -z ${tag} ]; then
    expdir=exp/${train_set}_${etype}_e${elayers}_subsample${subsample}_unit${eunits}_proj${eprojs}_d${dlayers}_unit${dunits}_${atype}_aconvc${aconv_chans}_aconvf${aconv_filts}_mtlalpha${mtlalpha}_${opt}_bs${batchsize}_mli${maxlen_in}_mlo${maxlen_out}
    if ${do_delta}; then
        expdir=${expdir}_delta
    fi
else
    expdir=exp/${train_set}_${tag}
fi
mkdir -p ${expdir}

if [ ${stage} -le 3 ]; then
    echo "stage 3: Network Training"
    ${cuda_cmd} ${expdir}/train.log \
	    asr_train.py \
	    --gpu ${gpu} \
	    --outdir ${expdir}/results \
	    --debugmode ${debugmode} \
	    --dict ${dict} \
	    --debugdir ${expdir} \
	    --minibatches ${N} \
	    --verbose ${verbose} \
	    --train-feat scp:${feat_tr_dir}/feats.scp \
	    --valid-feat scp:${feat_dt_dir}/feats.scp \
	    --train-label ${feat_tr_dir}/data.json \
	    --valid-label ${feat_dt_dir}/data.json \
	    --etype ${etype} \
	    --elayers ${elayers} \
	    --eunits ${eunits} \
	    --eprojs ${eprojs} \
	    --subsample ${subsample} \
	    --dlayers ${dlayers} \
	    --dunits ${dunits} \
	    --atype ${atype} \
	    --aconv-chans ${aconv_chans} \
	    --aconv-filts ${aconv_filts} \
	    --mtlalpha ${mtlalpha} \
	    --batch-size ${batchsize} \
	    --maxlen-in ${maxlen_in} \
	    --maxlen-out ${maxlen_out} \
	    --opt ${opt} \
	    --epochs ${epochs}
fi

if [ ${stage} -le 4 ]; then
    echo "stage 4: Decoding"
    nj=32

    for rtask in ${recog_set}; do
	(
	    decode_dir=decode_${rtask}_beam${beam_size}_e${recog_model}_p${penalty}_len${minlenratio}-${maxlenratio}

	    # split data
	    data=data/${rtask}
	    split_data.sh --per-utt ${data} ${nj};
	    sdata=${data}/split${nj}utt;

	    # feature extraction
	    feats="ark,s,cs:apply-cmvn --norm-vars=true data/${train_set}/cmvn.ark scp:${sdata}/JOB/feats.scp ark:- |"
	    if ${do_delta}; then
		feats="$feats add-deltas ark:- ark:- |"
	    fi

	    # make json labels for recognition
	    data2json.sh ${data} ${dict} > ${data}/data.json

	    #### use CPU for decoding
	    gpu=-1

	    ${decode_cmd} JOB=1:${nj} ${expdir}/${decode_dir}/log/decode.JOB.log \
			asr_recog.py \
			--gpu ${gpu} \
			--recog-feat "$feats" \
			--recog-label ${data}/data.json \
			--result-label ${expdir}/${decode_dir}/data.JOB.json \
			--model ${expdir}/results/model.${recog_model}  \
			--model-conf ${expdir}/results/model.conf  \
			--beam-size ${beam_size} \
			--penalty ${penalty} \
			--maxlenratio ${maxlenratio} \
			--minlenratio ${minlenratio} \
			&
	    wait

	    score_sclite.sh ${expdir}/${decode_dir} ${dict}

	) &
    done
    wait
    echo "Finished"
fi

