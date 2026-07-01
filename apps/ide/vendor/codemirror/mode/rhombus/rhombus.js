// CodeMirror, copyright (c) by Marijn Haverbeke and others
// Distributed under an MIT license: https://codemirror.net/5/LICENSE

// Rhombus mode for CodeMirror 5 (#lang rhombus and rhombus/* variants).
// Regex-based tokenizer using the stream API (same approach as mode/simple).

(function(mod) {
  if (typeof exports == "object" && typeof module == "object")
    mod(require("../../lib/codemirror"));
  else if (typeof define == "function" && define.amd)
    define(["../../lib/codemirror"], mod);
  else
    mod(CodeMirror);
})(function(CodeMirror) {
"use strict";

CodeMirror.defineMode("rhombus", function() {
  return {
    startState: function() { return { blockDepth: 0 }; },

    token: function(stream, state) {
      // #lang line: leave it entirely black
      if (stream.sol() && stream.match(/^#lang\b/)) {
        stream.skipToEnd();
        return null;
      }

      // Nested block comment /* ... */
      if (state.blockDepth > 0) {
        if (stream.match("/*")) { state.blockDepth++; return "comment"; }
        if (stream.match("*/")) { state.blockDepth--; return "comment"; }
        stream.next();
        return "comment";
      }

      if (stream.eatSpace()) return null;

      // Line comment //
      if (stream.match("//")) {
        stream.skipToEnd();
        return "comment";
      }

      // Block comment start /*
      if (stream.match("/*")) {
        state.blockDepth = 1;
        return "comment";
      }

      // String literal "..."
      if (stream.match('"')) {
        while (!stream.eol()) {
          var ch = stream.next();
          if (ch === '"') break;
          if (ch === '\\') stream.next();
        }
        return "rh-string";
      }

      // Boolean literal: #true, #false, #t, #f
      if (stream.match(/^#(?:true|false)\b/)) {
        return "rh-boolean";
      }

      // Number: #x hex, #b binary, #o octal, decimal/float
      if (stream.match(/^#[xXbBoO][0-9a-fA-F_]+/) ||
          stream.match(/^[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?/)) {
        return "rh-number";
      }

      // Shrubbery keyword ~ident
      if (stream.match(/^~[a-zA-Z_][a-zA-Z0-9_]*/)) {
        return "rh-paren";
      }

      // Brackets, parens, braces, single quote
      if (stream.match(/^[(){}\[\]']/)) {
        return "rh-paren";
      }

      // Identifier (covers keywords like def, fun, class, etc.)
      if (stream.match(/^[a-zA-Z_][a-zA-Z0-9_!?.]*/)) {
        return "rh-ident";
      }

      // Operator identifier (e.g. +, -, *, /, ==, !=, <, >, <=, >=, &&, ||, ...)
      if (stream.match(/^[+\-*\/=!<>&|^%@]+/)) {
        return null;
      }

      stream.next();
      return null;
    }
  };
});

CodeMirror.defineMIME("text/x-rhombus", "rhombus");

});
