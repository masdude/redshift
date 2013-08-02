from _state cimport *
from transitions cimport TransitionSystem

from libcpp.queue cimport priority_queue
from libcpp.utility cimport pair

cdef class Beam:
    cdef TransitionSystem trans
    cdef void** parents
    cdef void** beam
    cdef int** valid
    cdef int** costs
    
    cdef int init_beams(self, size_t k, size_t length) except -1
    cdef size_t max_class
    cdef size_t k
    cdef size_t i
    cdef size_t t
    cdef size_t nr_class
    cdef size_t length
    cdef size_t bsize
    cdef size_t psize
    cdef bint is_full
    cdef bint is_finished

    #cdef int init_beams(self, size_t k, size_t length) except -1
    cdef int swap_beam(self)

    cdef bint _is_finished(self, int p_or_b, size_t idx)
    cdef double get_score(self, size_t parent_idx)
    cdef int extend_states(self, double** scores) except -1
    cdef uint64_t extend_state(self, size_t parent_idx, size_t b_idx,
                          size_t clas, double score)
    cdef int fill_parse(self, size_t* hist, size_t* tags, size_t* heads,
                        size_t* labels, bint* sbd, bint* edits) except -1


cdef class ParseBeam(Beam):

    cdef int init_beams(self, size_t k, size_t length) except -1
    cdef bint _is_finished(self, int p_or_b, size_t idx)
    cdef double get_score(self, size_t parent_idx)
    cdef int extend_states(self, double** scores) except -1
    cdef uint64_t extend_state(self, size_t parent_idx, size_t b_idx,
                          size_t clas, double score)
    cdef int fill_parse(self, size_t* hist, size_t* tags, size_t* heads,
                        size_t* labels, bint* sbd, bint* edits) except -1


cdef class TaggerBeam(Beam):
    cdef int init_beams(self, size_t k, size_t length) except -1
    cdef bint _is_finished(self, int p_or_b, size_t idx)
    cdef double get_score(self, size_t parent_idx)
    cdef int extend_states(self, double** scores) except -1
    cdef uint64_t extend_state(self, size_t parent_idx, size_t b_idx,
                          size_t clas, double score)
    cdef int fill_parse(self, size_t* hist, size_t* tags, size_t* heads,
                        size_t* labels, bint* sbd, bint* edits) except -1
    cdef int eval_beam(self, size_t* gold) 

cdef struct TagKernel:
    size_t ptag
    size_t pptag
    size_t ppptag
    size_t i


cdef struct TagState:
    size_t* tags
    TagKernel kernel
    double score
    size_t cost

