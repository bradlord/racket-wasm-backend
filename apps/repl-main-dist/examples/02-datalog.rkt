#lang datalog

%% A different #lang entirely: Datalog, the deductive database
%% language, shipped in the WASM image. Facts end in `.`, rules use
%% `:-`, and lines ending in `?` are queries -- their answers print
%% when you Run.

parent(john, douglas).
parent(bob, john).
parent(ebbon, bob).

ancestor(A, B) :- parent(A, B).
ancestor(A, B) :- parent(A, C), ancestor(C, B).

%% Who is an ancestor of whom?
ancestor(A, B)?

%% Just ebbon's descendants:
ancestor(ebbon, B)?
