from redshift._state cimport *
from redshift.beam cimport TaggerBeam, TagState, fill_hist, get_p, get_pp, extend_state
#, TagKernel
from features.extractor cimport Extractor
from learn.perceptron cimport Perceptron
import index.hashes
cimport index.hashes
from redshift.io_parse cimport Sentences, Sentence
from libc.stdlib cimport malloc, calloc, free
from libc.string cimport memcpy, memset
from libc.stdint cimport uint64_t, int64_t
from libcpp.vector cimport vector 

from os.path import join as pjoin
import os
import os.path
from os.path import join as pjoin
import random
import shutil

DEBUG = False

cdef class BeamTagger:
    cdef Extractor features
    cdef Perceptron guide
    cdef object model_dir
    cdef size_t beam_width
    cdef int feat_thresh
    cdef size_t max_feats
    cdef size_t nr_tag
    cdef size_t _acc

    cdef size_t* _context
    cdef uint64_t* _features
    cdef double** beam_scores

    def __cinit__(self, model_dir, feat_set="basic", feat_thresh=5, beam_width=4,
                  clean=False, trained=False):
        assert not (clean and trained)
        self.model_dir = model_dir
        if clean and os.path.exists(model_dir):
            shutil.rmtree(model_dir)
            os.mkdir(model_dir)
            self.new_idx(model_dir)
        elif trained:
            self.load_idx(model_dir)
            self.guide.load(pjoin(model_dir, 'tagger.gz'), thresh=self.feat_thresh)
        self.feat_thresh = feat_thresh
        self.guide = Perceptron(100, pjoin(model_dir, 'tagger.gz'))
        if trained:
            self.guide.load(pjoin(model_dir, 'tagger.gz'), thresh=self.feat_thresh)
        self.features = Extractor(basic + clusters, [])
        self.nr_tag = 100
        self.beam_width = beam_width
        self._context = <size_t*>calloc(CONTEXT_SIZE, sizeof(size_t))
        self.max_feats = self.features.nr_template + self.features.nr_bow + 100
        self._features = <uint64_t*>calloc(self.max_feats, sizeof(uint64_t))
        self.beam_scores = <double**>malloc(sizeof(double*) * self.beam_width)
        for i in range(self.beam_width):
            self.beam_scores[i] = <double*>calloc(self.nr_tag, sizeof(double))

    def add_tags(self, Sentences sents):
        cdef size_t i
        for i in range(sents.length):
            self.tag(sents.s[i])

    cdef int tag(self, Sentence* sent) except -1:
        cdef TaggerBeam beam = TaggerBeam(None, self.beam_width, sent.length, self.nr_tag)
        cdef size_t p_idx
        cdef TagState* s
        for i in range(sent.length - 1):
            self.fill_beam_scores(beam, sent, i)
            beam.extend_states(self.beam_scores)
        s = <TagState*>beam.beam[0]
        fill_hist(sent.pos, s, sent.length - 1)

    cdef int fill_beam_scores(self, TaggerBeam beam, Sentence* sent,
                              size_t word_i) except -1:
        for i in range(beam.bsize):
            # At this point, beam.clas is the _last_ prediction, not the prediction
            # for this instance
            fill_context(self._context, sent, beam.parents[i].clas,
                         get_p(beam.parents[i]),
                         beam.parents[i].alt, word_i)
            self.features.extract(self._features, self._context)
            self.guide.fill_scores(self._features, self.beam_scores[i])
 
    def train(self, Sentences sents, nr_iter=10):
        self.nr_tag = 0
        tags = set()
        for i in range(sents.length):
            for j in range(sents.s[i].length):
                if sents.s[i].pos[j] >= self.nr_tag:
                    self.nr_tag = sents.s[i].pos[j]
                    tags.add(sents.s[i].pos[j])
        self.nr_tag += 1
        self.guide.set_classes(range(self.nr_tag))
        indices = list(range(sents.length))
        for n in range(nr_iter):
            for i in indices:
                if DEBUG:
                    print ' '.join(sents.strings[i][0])
                self.static_train(n, sents.s[i])
            print_train_msg(n, self.guide.n_corr, self.guide.total, self.guide.cache.n_hit,
                            self.guide.cache.n_miss)
            self.guide.n_corr = 0
            self.guide.total = 0
            if n % 2 == 1 and self.feat_thresh > 1:
                self.guide.prune(self.feat_thresh)
            if n < 3:
                self.guide.reindex()
            random.shuffle(indices)
        self.guide.finalize()

    cdef int static_train(self, int iter_num, Sentence* sent) except -1:
        cdef size_t  i, tmp
        cdef TaggerBeam beam = TaggerBeam(None, self.beam_width, sent.length, self.nr_tag)
        cdef TagState* gold_state = extend_state(NULL, 0, NULL, 0)
        cdef MaxViolnUpd updater = MaxViolnUpd(self.nr_tag)
        for i in range(sent.length - 1):
            gold_state = self.extend_gold(gold_state, sent, i)
            self.fill_beam_scores(beam, sent, i)
            beam.extend_states(self.beam_scores)
            #if beam.beam[0].alt == gold_state.clas and beam.beam[0].alt != 0:
            #    tmp = gold_state.clas
            #    gold_state.alt = gold_state.clas
            #    gold_state.clas = tmp
            updater.compare(beam.beam[0], gold_state, i)
            self.guide.n_corr += (gold_state.clas == beam.beam[0].clas)
            self.guide.total += 1
        counts = updater.count_feats(self._features, self._context, sent, self.features)
        if updater.delta != -1:
            self.guide.batch_update(counts)
        else:
            self.guide.now += 1

    cdef TagState* extend_gold(self, TagState* s, Sentence* sent, size_t i) except NULL:
        if i >= 1:
            assert s.clas == sent.pos[i - 1]
        else:
            assert s.clas == 0
        fill_context(self._context, sent, s.clas, get_p(s), s.alt, i)
        self.features.extract(self._features, self._context)
        self.guide.fill_scores(self._features, self.guide.scores)
        ext = extend_state(s, sent.pos[i], self.guide.scores, self.guide.nr_class)
        return ext

    def save(self):
        self.guide.save(pjoin(self.model_dir, 'tagger.tgz'))

    def load(self):
        self.guide.load(pjoin(self.model_dir, 'model.gz'), thresh=self.feat_thresh)

    def new_idx(self, model_dir):
        index.hashes.init_word_idx(pjoin(model_dir, 'words'))
        index.hashes.init_pos_idx(pjoin(model_dir, 'pos'))
        index.hashes.init_label_idx(pjoin(model_dir, 'labels'))

    def load_idx(self, model_dir):
        index.hashes.load_word_idx(pjoin(model_dir, 'words'))
        index.hashes.load_pos_idx(pjoin(model_dir, 'pos'))
        index.hashes.load_label_idx(pjoin(model_dir, 'labels'))


cdef class MaxViolnUpd:
    cdef TagState* pred
    cdef TagState* gold
    cdef Sentence* sent
    cdef double delta
    cdef int length
    cdef size_t nr_class
    cdef size_t tmp
    def __cinit__(self, size_t nr_class):
        self.delta = -1
        self.length = -1
        self.nr_class = nr_class

    cdef int compare(self, TagState* pred, TagState* gold, size_t i):
        delta = pred.score - gold.score
        if delta > self.delta:
            self.delta = delta
            self.pred = pred
            self.gold = gold
            self.length = i 

    cdef dict count_feats(self, uint64_t* feats, size_t* context, Sentence* sent,
                          Extractor extractor):
        if self.length == -1:
            return {}
        cdef TagState* g = self.gold
        cdef TagState* p = self.pred
        cdef int i = self.length
        cdef dict counts = {}
        for clas in range(self.nr_class):
            counts[clas] = {} 
        cdef size_t gclas, gprev, gprevprev
        cdef size_t pclas, pprev, prevprev
        while g != NULL and p != NULL and i >= 0:
            gclas = g.clas
            gprev = get_p(g)
            gprevprev = get_pp(g)
            galt = g.alt
            pclas = p.clas
            pprev = get_p(p)
            pprevprev = get_pp(p)
            palt = p.alt
            if gclas == pclas and pprev == gprev and gprevprev == pprevprev:
                g = g.prev
                p = p.prev
                i -= 1
                continue
            fill_context(context, sent, gprev, gprevprev,
                         g.prev.alt if g.prev != NULL else 0, i)
            extractor.extract(feats, context)
            self._inc_feats(counts[gclas], feats, 1.0)
            fill_context(context, sent, pprev, pprevprev,
                         p.prev.alt if p.prev != NULL else 0, i)
            extractor.extract(feats, context)
            self._inc_feats(counts[p.clas], feats, -1.0)
            assert sent.words[i] == context[N0w]
            g = g.prev
            p = p.prev
            i -= 1
        return counts

    cdef int _inc_feats(self, dict counts, uint64_t* feats,
                        double inc) except -1:
        cdef size_t f = 0
        while feats[f] != 0:
            if feats[f] not in counts:
                counts[feats[f]] = 0
            counts[feats[f]] += inc
            f += 1


def print_train_msg(n, n_corr, n_move, n_hit, n_miss):
    pc = lambda a, b: '%.1f' % ((float(a) / (b + 1e-100)) * 100)
    move_acc = pc(n_corr, n_move)
    cache_use = pc(n_hit, n_hit + n_miss + 1e-100)
    msg = "#%d: Moves %d/%d=%s" % (n, n_corr, n_move, move_acc)
    if cache_use != 0:
        msg += '. Cache use %s' % cache_use
    print msg


cdef enum:
    N0w
    N0c
    N0c6
    N0c4
    N0suff
    N0pre

    N0quo

    N1w
    N1c
    N1c6
    N1c4
    N1suff
    N1pre

    N2w
    N2c
    N2c6
    N2c4
    N2suff
    N2pre

    P1w
    P1c
    P1c6
    P1c4
    P1suff
    P1pre
    P1p
    P1alt

    P2w
    P2c
    P2c6
    P2c4
    P2suff
    P2pre
    P2p

    P3w # For BOW
    P4w
    P5w
    P6w
    P7w
    CONTEXT_SIZE

#basic = ((N0w,), (P1p,),)

basic = (
    (N0w,),
    (N1w,),
    (P1p,),
    (P2p,),
    (P1p, P2p),
    (P1p, N0w),
    (N0suff,),
    (N0pre,),
    (N1suff,),
    (N1pre,),
    (P1suff,),
    (P1pre,),
    #(N0quo,),
    (N0w, N0quo),
    (P1p, N0quo),
    (N2w,),
    (N2c,),
    #(P1alt,),
)

clusters = (
    (N0c,),
    (N0c4,),
    (N0c6,),
    (P1c,),
    (P1c4,),
    (P1c6,),
    (N1c,),
    (N1c4,),
    (N1c6,),
    (P1c, N0w),
    (P1p, P1c6, N0w),
    (P1c6, N0w),
    (N0w, N1c),
    (N0w, N1c6),
    (N0w, N1c4),
    (P2c4, P1c4, N0w)
)


cdef int fill_context(size_t* context, Sentence* sent, size_t ptag, size_t pptag,
                      size_t p_alt, size_t i):
    context[N0w] = sent.words[i]
    context[N0c] = sent.clusters[i]
    context[N0c6] = sent.cprefix6s[i]
    context[N0c4] = sent.cprefix4s[i]
    context[N0suff] = sent.orths[i]
    context[N0pre] = sent.parens[i]
    
    context[N1w] = sent.words[i + 1]
    context[N1c] = sent.clusters[i + 1]
    context[N1c6] = sent.cprefix6s[i + 1]
    context[N1c4] = sent.cprefix4s[i + 1]
    context[N1suff] = sent.orths[i + 1]
    context[N1pre] = sent.parens[i + 1]

    context[N0quo] = sent.quotes[i] == 0
    if i == 1:
        return 0
    context[P1w] = sent.words[i-1]
    context[P1c] = sent.clusters[i-1]
    context[P1c6] = sent.cprefix6s[i-1]
    context[P1c4] = sent.cprefix4s[i-1]
    context[P1suff] = sent.orths[i-1]
    context[P1pre] = sent.parens[i-1]
    context[P1p] = ptag
    context[P1alt] = p_alt
    if i == 2:
        return 0
    context[P2w] = sent.words[i-2]
    context[P2c] = sent.clusters[i-2]
    context[P2c6] = sent.cprefix6s[i-2]
    context[P2c4] = sent.cprefix4s[i-2]
    context[P2suff] = sent.orths[i-2]
    context[P2pre] = sent.parens[i-2]
    context[P2p] = pptag

    # Fill bag-of-words slots
    #cdef size_t slot = P3w
    #i -= 2
    #while i > 0 and slot < CONTEXT_SIZE:
    #    i -= 1
    #    context[slot] = sent.words[i]
    #    slot += 1
