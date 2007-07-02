#reader(lib "docreader.ss" "scribble")
@require["mz.ss"]

@title{PLT Scheme Reference Manual}

This manual defines the core PLT Scheme language and describes its
most prominent libraries. The companion manual
@italic{@link["../guide/index.html"]{A Guide to PLT Scheme}} provides
a friendlier (though less precise and less complete) overview of the
language.

@bold{This reference describes a potential future version of PLT Scheme.
      It does not match the current implementation.}

@table-of-contents[]

@include-section["model.scrbl"]
@include-section["syntax-model.scrbl"]
@include-section["read.scrbl"]
@include-section["syntax.scrbl"]
@include-section["derived.scrbl"]
@include-section["data.scrbl"]
@include-section["struct.scrbl"]

@;------------------------------------------------------------------------
@section["Input and Output"]

@subsection[#:tag "mz:char-input"]{From Bytes to Characters}

@;------------------------------------------------------------------------
@include-section["regexps.scrbl"]
@include-section["control.scrbl"]
@include-section["concurrency.scrbl"]
@include-section["custodians.scrbl"]

@;------------------------------------------------------------------------

@section{Platform-Specific Path Conventions}

@subsection[#:tag "mz:unix-path"]{Unix and Mac OS X Paths}

@subsection[#:tag "mz:windows-path"]{Windows Paths}

@;------------------------------------------------------------------------

@index-section["mzscheme-index"]
