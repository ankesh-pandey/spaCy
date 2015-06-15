# cython: profile=True
from __future__ import unicode_literals

import ctypes
import os

from ..structs cimport TokenC

from .transition_system cimport do_func_t, get_cost_func_t
from .transition_system cimport move_cost_func_t, label_cost_func_t
from ..gold cimport GoldParse
from ..gold cimport GoldParseC

from libc.stdint cimport uint32_t
from libc.string cimport memcpy

from cymem.cymem cimport Pool
from .stateclass cimport StateClass


cdef weight_t MIN_SCORE = -90000

cdef enum:
    SHIFT
    REDUCE
    LEFT
    RIGHT

    N_MOVES


MOVE_NAMES = [None] * N_MOVES
MOVE_NAMES[SHIFT] = 'S'
MOVE_NAMES[REDUCE] = 'D'
MOVE_NAMES[LEFT] = 'L'
MOVE_NAMES[RIGHT] = 'R'


# Helper functions for the arc-eager oracle

cdef int push_cost(StateClass stcls, const GoldParseC* gold, int target) nogil:
    cdef int cost = 0
    cdef int i, S_i
    for i in range(stcls.stack_depth()):
        S_i = stcls.S(i)
        if gold.heads[target] == S_i:
            cost += 1
        if gold.heads[S_i] == target and not stcls.has_head(S_i):
            cost += 1
    return cost


cdef int pop_cost(StateClass stcls, const GoldParseC* gold, int target) nogil:
    if stcls.buffer_length() == 0:
        return 0
    cdef int cost = 0
    cdef int i, B_i
    for i in range(stcls.buffer_length()):
        B_i = stcls.B(i)
        cost += gold.heads[B_i] == target
        if not stcls.has_head(target):
            cost += gold.heads[target] == B_i
        if gold.heads[B_i] == B_i or gold.heads[B_i] < target:
            break
    return cost


cdef int arc_cost(StateClass stcls, const GoldParseC* gold, int head, int child) nogil:
    if arc_is_gold(gold, head, child):
        return 0
    elif stcls.H(child) == gold.heads[child]:
        return 1
    # Head in buffer
    elif gold.heads[child] >= stcls.B(0) and stcls.B(1) != -1:
        return 1
    else:
        return 0


cdef bint arc_is_gold(const GoldParseC* gold, int head, int child) nogil:
    if gold.labels[child] == -1:
        return True
    elif gold.heads[child] == head:
        return True
    else:
        return False


cdef bint label_is_gold(const GoldParseC* gold, int head, int child, int label) nogil:
    if gold.labels[child] == -1:
        return True
    elif label == -1:
        return True
    elif gold.labels[child] == label:
        return True
    else:
        return False


cdef bint _is_gold_root(const GoldParseC* gold, int word) nogil:
    return gold.labels[word] == -1 or gold.heads[word] == word
 

cdef class Shift:
    @staticmethod
    cdef bint is_valid(StateClass st, int label) nogil:
        return st.buffer_length() >= 1

    @staticmethod
    cdef int transition(StateClass st, int label) nogil:
        st.push()

    @staticmethod
    cdef int cost(StateClass st, const GoldParseC* gold, int label) nogil:
        return Shift.move_cost(st, gold) + Shift.label_cost(st, gold, label)

    @staticmethod
    cdef inline int move_cost(StateClass s, const GoldParseC* gold) nogil:
        return push_cost(s, gold, s.B(0))

    @staticmethod
    cdef inline int label_cost(StateClass s, const GoldParseC* gold, int label) nogil:
        return 0


cdef class Reduce:
    @staticmethod
    cdef bint is_valid(StateClass st, int label) nogil:
        return st.stack_depth() >= 1 and st.has_head(st.S(0))

    @staticmethod
    cdef int transition(StateClass st, int label) nogil:
        st.pop()

    @staticmethod
    cdef int cost(StateClass s, const GoldParseC* gold, int label) nogil:
        return Reduce.move_cost(s, gold) + Reduce.label_cost(s, gold, label)

    @staticmethod
    cdef inline int move_cost(StateClass st, const GoldParseC* gold) nogil:
        return pop_cost(st, gold, st.S(0))

    @staticmethod
    cdef inline int label_cost(StateClass s, const GoldParseC* gold, int label) nogil:
        return 0


cdef class LeftArc:
    @staticmethod
    cdef bint is_valid(StateClass st, int label) nogil:
        return st.stack_depth() >= 1 and not st.has_head(st.S(0))

    @staticmethod
    cdef int transition(StateClass st, int label) nogil:
        if not st.buffer_length():
            st.add_arc(st.S(0), st.S(0), label)
        else:
            st.add_arc(st.B(0), st.S(0), label)
        st.pop()

    @staticmethod
    cdef int cost(StateClass s, const GoldParseC* gold, int label) nogil:
        return LeftArc.move_cost(s, gold) + LeftArc.label_cost(s, gold, label)

    @staticmethod
    cdef inline int move_cost(StateClass s, const GoldParseC* gold) nogil:
        if not s.buffer_length():
            return 0
        elif arc_is_gold(gold, s.B(0), s.S(0)):
            return 0
        else:
            return pop_cost(s, gold, s.S(0)) + arc_cost(s, gold, s.B(0), s.S(0))

    @staticmethod
    cdef inline int label_cost(StateClass s, const GoldParseC* gold, int label) nogil:
        if not s.buffer_length():
            return 0
        return arc_is_gold(gold, s.B(0), s.S(0)) and not label_is_gold(gold, s.B(0), s.S(0), label)


cdef class RightArc:
    @staticmethod
    cdef bint is_valid(StateClass st, int label) nogil:
        return st.stack_depth() >= 1 and st.buffer_length() >= 1

    @staticmethod
    cdef int transition(StateClass st, int label) nogil:
        st.add_arc(st.S(0), st.B(0), label)
        st.push()

    @staticmethod
    cdef inline int cost(StateClass s, const GoldParseC* gold, int label) nogil:
        return RightArc.move_cost(s, gold) + RightArc.label_cost(s, gold, label)

    @staticmethod
    cdef inline int move_cost(StateClass s, const GoldParseC* gold) nogil:
        if arc_is_gold(gold, s.S(0), s.B(0)):
            return 0
        elif s.shifted[s.B(0)]:
            return push_cost(s, gold, s.B(0))
        else:
            return push_cost(s, gold, s.B(0)) + arc_cost(s, gold, s.S(0), s.B(0))

    @staticmethod
    cdef int label_cost(StateClass s, const GoldParseC* gold, int label) nogil:
        return arc_is_gold(gold, s.S(0), s.B(0)) and not label_is_gold(gold, s.S(0), s.B(0), label)


cdef class OrigArcEager(TransitionSystem):
    @classmethod
    def get_labels(cls, gold_parses):
        move_labels = {SHIFT: {'': True}, RIGHT: {'': True},
                       REDUCE: {'': True}, LEFT: {'root': True}}
        for raw_text, sents in gold_parses:
            for (ids, words, tags, heads, labels, iob), ctnts in sents:
                for child, head, label in zip(ids, heads, labels):
                    if label != 'root':
                        if head < child:
                            move_labels[RIGHT][label] = True
                        elif head > child:
                            move_labels[LEFT][label] = True
        return move_labels

    cdef int preprocess_gold(self, GoldParse gold) except -1:
        for i in range(gold.length):
            if gold.heads[i] is None: # Missing values
                gold.c.heads[i] = i
                gold.c.labels[i] = -1
            else:
                gold.c.heads[i] = gold.heads[i]
                gold.c.labels[i] = self.strings[gold.labels[i]]
        for end, brackets in gold.brackets.items():
            for start, label_strs in brackets.items():
                gold.c.brackets[start][end] = 1
                for label_str in label_strs:
                    # Add the encoded label to the set
                    gold.brackets[end][start].add(self.strings[label_str])

    cdef Transition lookup_transition(self, object name) except *:
        if '-' in name:
            move_str, label_str = name.split('-', 1)
            label = self.label_ids[label_str]
        else:
            label = 0
        move = MOVE_NAMES.index(move_str)
        for i in range(self.n_moves):
            if self.c[i].move == move and self.c[i].label == label:
                return self.c[i]

    def move_name(self, int move, int label):
        label_str = self.strings[label]
        if label_str:
            return MOVE_NAMES[move] + '-' + label_str
        else:
            return MOVE_NAMES[move]

    cdef Transition init_transition(self, int clas, int move, int label) except *:
        # TODO: Apparent Cython bug here when we try to use the Transition()
        # constructor with the function pointers
        cdef Transition t
        t.score = 0
        t.clas = clas
        t.move = move
        t.label = label
        if move == SHIFT:
            t.is_valid = Shift.is_valid
            t.do = Shift.transition
            t.get_cost = Shift.cost
        elif move == REDUCE:
            t.is_valid = Reduce.is_valid
            t.do = Reduce.transition
            t.get_cost = Reduce.cost
        elif move == LEFT:
            t.is_valid = LeftArc.is_valid
            t.do = LeftArc.transition
            t.get_cost = LeftArc.cost
        elif move == RIGHT:
            t.is_valid = RightArc.is_valid
            t.do = RightArc.transition
            t.get_cost = RightArc.cost
        else:
            raise Exception(move)
        return t

    cdef int initialize_state(self, StateClass st) except -1:
        # Ensure sent_end is set to 0 throughout
        for i in range(st.length):
            st._sent[i].sent_end = False
        st.push()

    cdef int finalize_state(self, StateClass st) except -1:
        cdef int root_label = self.strings['root']
        for i in range(st.length):
            if st._sent[i].head == 0:
                st._sent[i].dep = root_label

    cdef int set_valid(self, bint* output, StateClass stcls) except -1:
        cdef bint[N_MOVES] is_valid
        is_valid[SHIFT] = Shift.is_valid(stcls, -1)
        is_valid[REDUCE] = Reduce.is_valid(stcls, -1)
        is_valid[LEFT] = LeftArc.is_valid(stcls, -1)
        is_valid[RIGHT] = RightArc.is_valid(stcls, -1)
        cdef int i
        n_valid = 0
        for i in range(self.n_moves):
            output[i] = is_valid[self.c[i].move]
            n_valid += output[i]
        assert n_valid >= 1

    cdef int set_costs(self, int* output, StateClass stcls, GoldParse gold) except -1:
        cdef int i, move, label
        cdef label_cost_func_t[N_MOVES] label_cost_funcs
        cdef move_cost_func_t[N_MOVES] move_cost_funcs
        cdef int[N_MOVES] move_costs
        for i in range(N_MOVES):
            move_costs[i] = -1
        move_cost_funcs[SHIFT] = Shift.move_cost
        move_cost_funcs[REDUCE] = Reduce.move_cost
        move_cost_funcs[LEFT] = LeftArc.move_cost
        move_cost_funcs[RIGHT] = RightArc.move_cost

        label_cost_funcs[SHIFT] = Shift.label_cost
        label_cost_funcs[REDUCE] = Reduce.label_cost
        label_cost_funcs[LEFT] = LeftArc.label_cost
        label_cost_funcs[RIGHT] = RightArc.label_cost

        cdef int* labels = gold.c.labels
        cdef int* heads = gold.c.heads

        n_gold = 0
        for i in range(self.n_moves):
            if self.c[i].is_valid(stcls, self.c[i].label):
                move = self.c[i].move
                label = self.c[i].label
                if move_costs[move] == -1:
                    move_costs[move] = move_cost_funcs[move](stcls, &gold.c)
                output[i] = move_costs[move] + label_cost_funcs[move](stcls, &gold.c, label)
                n_gold += output[i] == 0
            else:
                output[i] = 9000
        assert n_gold >= 1

    cdef Transition best_valid(self, const weight_t* scores, StateClass stcls) except *:
        cdef bint[N_MOVES] is_valid
        is_valid[SHIFT] = Shift.is_valid(stcls, -1)
        is_valid[REDUCE] = Reduce.is_valid(stcls, -1)
        is_valid[LEFT] = LeftArc.is_valid(stcls, -1)
        is_valid[RIGHT] = RightArc.is_valid(stcls, -1)
        cdef Transition best
        cdef weight_t score = MIN_SCORE
        cdef int i
        for i in range(self.n_moves):
            if scores[i] > score and is_valid[self.c[i].move]:
                best = self.c[i]
                score = scores[i]
        assert score > MIN_SCORE, (self.n_moves, stcls.stack_depth(), stcls.buffer_length(), stcls.is_final(), stcls._b_i, stcls.length, stcls.has_head(stcls.S(0)), LeftArc.is_valid(stcls, -1))
        return best