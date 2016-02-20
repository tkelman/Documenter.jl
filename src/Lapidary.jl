__precompile__(true)

"""
Lapidary.jl -- a documentation generator for Julia.
"""
module Lapidary

export makedocs

using Base.Meta

# types
# =====

typealias Str UTF8String

"""
    State

Used to store the current state of the markdown template expansion. This simplifies the
[`expand`]({ref}) methods by avoiding having to thread all the state between each call
manually.
"""
immutable State
    src    :: Str
    dst    :: Str
    blocks :: Vector{Any}
    meta   :: Dict{Symbol, Any}
end
State(src, dst) = State(src, dst, [], Dict())
State()         = State("",  "",  [], Dict())

"""
    Path

Represents a file mapping from source file `.src` to destination file `.dst`.
"""
immutable Path
    src :: Str
    dst :: Str
end

"""
    ParsedPath

Same as [`Path`]({ref}), but also includes the parsed content of the markdown file.
"""
immutable ParsedPath
    src :: Str
    dst :: Str
    ast :: Markdown.MD
end

"""
    HeaderPath

Represents a file mapping from `.src` to `.dst` of a markdown header element. The `.nth`
field tracks the ordering of the headers within the file.
"""
immutable HeaderPath
    src :: Str
    dst :: Str
    nth :: Int
    ast :: Markdown.Header
end

"""
    Env

Stores all the state associated with a document. An instance of this type is threaded
through the sequence of transformations used to build the document.
"""
type Env{MIMETYPE}
    # paths
    root   :: Str
    source :: Str
    build  :: Str
    assets :: Str
    # misc
    clean  :: Bool
    mime   :: MIMETYPE
    # state
    template_paths     :: Vector{Path}
    parsed_templates   :: Vector{ParsedPath}
    expanded_templates :: Vector{State}
    state              :: State
    headers            :: Dict{Str, HeaderPath}
    headermap          :: ObjectIdDict
    docsmap            :: ObjectIdDict
end

"""
    Env(kwargs...)

Helper method used to simplidy the construction of [`Env`]({ref}) objects. Takes any number
of keyword arguments. Note that unknown keyword arguments are discarded by this method.
"""
function Env(;
        root   = currentdir(),
        source = "src",
        build  = "build",
        assets = assetsdir(),
        clean  = true,
        mime   = MIME"text/plain"()
    )
    Env{typeof(mime)}(
        root, source, build, assets, clean, mime,
        [], [], [], State(),
        Dict(), ObjectIdDict(), ObjectIdDict()
    )
end

# user-interface
# ==============

"""
    makedocs(
        src    = "src",
        build  = "build",
        format = ".md",
        clean  = true
    )

Converts markdown formatted template files found in `src` into `format`-formatted files in
the `build` directory. Option `clean` will empty out the `build` directory prior to building
new documentation.

`src` and `build` paths are set relative to the file from which `makedocs` is called. The
standard directory setup for using `makedocs` is as follows:

    docs/
        build/
        src/
        make.jl

where `make.jl` contains

    using Lapidary
    makedocs(
        # options...
    )

Any non-markdown files found in the `src` directory are copied over to the `build` directory
without change. Markdown files are those with the extension `.md` only.
"""
function makedocs(; args...)
    env = Env(; args...)
    cd(env.root) do
        process(
            env,
            SetupBuildDirectory(),
            CopyAssetsDirectory(),
            ParseTemplates(),
            ExpandTemplates(
                FindHeaders(),
                MetaBlock(),
                DocsBlock(),
                IndexBlock(),
                ContentsBlock(),
                DefaultExpander()
            ),
            CrossReferenceLinks(),
            RunDocTests(),
            RenderDocument()
        )
    end
end

# stages
# ======

## setup build directory
## =====================

"""
    SetupBuildDirectory

Cleans out previous `build` directory and rebuilds the folder structure to match that of the
`src` directory. Copies all non-markdown files from `src` to `build`.
"""
immutable SetupBuildDirectory end

function (::SetupBuildDirectory)(env)
    env.clean && isdir(env.build) && rm(env.build; recursive = true)
    isdir(env.build) || mkdir(env.build)
    if isdir(env.source)
        for (root, dirs, files) in walkdir(env.source)
            for dir in dirs
                d = normpath(joinpath(env.build, relpath(root, env.source), dir))
                isdir(d) || mkdir(d)
            end
            for file in files
                src = normpath(joinpath(root, file))
                dst = normpath(joinpath(env.build, relpath(root, env.source), file))
                if endswith(src, ".md")
                    push!(env.template_paths, Path(src, dst))
                else
                    cp(src, dst; remove_destination = true)
                end
            end
        end
    else
        error("source directory '$(abspath(env.source))' is missing.")
    end
end
log(io, ::SetupBuildDirectory) = log(io, "setting up build directory.")

## copy asset directory
## ====================

"""
    CopyAssetsDirectory

Copies the contents of the Lapidary `assets` folder to `build/assets`.

Will throw an error if the directory already exists.
"""
immutable CopyAssetsDirectory end

function (::CopyAssetsDirectory)(env)
    if isdir(env.assets)
        dst = joinpath(env.build, "assets")
        if isdir(dst)
            error("'$(abs(dst))' is a reserved directory name.")
        else
            cp(env.assets, dst; remove_destination = true)
        end
    else
        error("assets directory '$(abspath(env.assets))' is missing.")
    end
end
log(io, ::CopyAssetsDirectory) = log(io, "copying assets to build directory.")

## parse templates
## ===============

"""
    ParseTemplates

Reads the contents of each markdown file found in `src` and them into `Markdown.MD` objects
using `Markdown.parse`.
"""
immutable ParseTemplates end

function (::ParseTemplates)(env)
    for path in env.template_paths
        ast = Markdown.parse(readstring(path.src))
        push!(env.parsed_templates, ParsedPath(path.src, path.dst, ast))
    end
end
log(io, ::ParseTemplates) = log(io, "parsing markdown templates.")

## expand templates
## ================

"""
    ExpandTemplates

Runs all the expanders stored in `.expanders` on each element of the parsed markdown files.
"""
immutable ExpandTemplates{E}
    expanders :: E
    (::Type{ExpandTemplates})(x...) = new{Tuple{map(typeof, x)...}}(x)
end

function (E::ExpandTemplates)(env)
    for each in env.parsed_templates
        env.state = State(each.src, each.dst)
        for block in each.ast.content
            for x in E.expanders
                expand(x, block, env) && break
            end
        end
        push!(env.expanded_templates, env.state)
    end
end
log(io, ::ExpandTemplates) = log(io, "expanding parsed template files.")

### expanders
### =========

abstract AbstractExpander

"""
    expand

Expand a single element, `block`, of a markdown file.
"""
expand(::AbstractExpander, block, env) = false

# default expander
# ----------------

"""
    DefaultExpander

By default block expansion just pushes the block onto the end of the vector of expanded blocks.
"""
immutable DefaultExpander <: AbstractExpander end

function expand(::DefaultExpander, block, env)
    blocks = env.state.blocks
    push!(blocks, block)
    true
end

# header tracking
# ---------------

"""
    FindHeaders

An expander that tracks all header elements in a document. The data gathered by this expander
is used in later stages to build cross-reference links and tables of contents.
"""
immutable FindHeaders <: AbstractExpander end

const HEADER_ID_REGEX = r"^{#(.+)}$"

function is_custom_header_id(b)
    isa(b.text, Vector) &&
    length(b.text) === 1 &&
    isa(b.text[1], Markdown.Link) &&
    ismatch(HEADER_ID_REGEX, b.text[1].url)
end

function expand{N}(::FindHeaders, b::Markdown.Header{N}, env)
    # Generate a unique ID for the current header `b`.
    id =
        if is_custom_header_id(b)
            url = b.text[1].url
            # MUTATE HEADER! Remove outer link leaving just link text.
            b.text = b.text[1].text
            # Extract the ID for the header.
            match(HEADER_ID_REGEX, url)[1]
        else
            sprint(Markdown.plain, Markdown.Paragraph(b.text))
        end
    id = slugify(id)

    counter = length(env.headers)
    src     = env.state.src
    dst     = env.state.dst

    # Require all headers to have distinct IDs.
    haskey(env.headers, id) && error("duplicate header id '$(id)' in '$(abspath(src))'.")
    env.headers[id]  = HeaderPath(src, dst, counter, b)
    env.headermap[b] = id
    push!(env.state.blocks, b)
    true
end

# {meta} block
# ------------

"""
    MetaBlock

Expands markdown code blocks where the first line contains `{meta}`. The expander parses
the contents of the block expecting key/value pairs such as

    {meta}
    CurrentModule = Lapidary

Note that all syntax used in the block must be valid Julia syntax.
"""
immutable MetaBlock <: AbstractExpander end

"""
    MetaNode

Stores the parsed and evaluated key/value pairs found in a `{meta}` block.
"""
immutable MetaNode
    dict :: Dict{Symbol, Any}
end

function expand(::MetaBlock, b::Markdown.Code, env)
    startswith(b.code, "{meta}") || return false
    meta = env.state.meta
    for (ex, str) in parseblock(b.code; skip = 1)
        isassign(ex) && (meta[ex.args[1]] = eval(current_module(), ex.args[2]))
    end
    push!(env.state.blocks, MetaNode(copy(meta)))
    true
end

# {docs} block
# ------------

"""
    DocsBlock

Expands code blocks where the first line contains `{docs}`. Subsequent lines should be names
of objects whose documentation should be retrieved from the Julia docsystem.

    {docs}
    foo
    bar(x, y)
    Baz.@baz

Each object is evaluated in the `current_module()` or `CurrentModule` if that has been set
in a `{meta}` block of the current page prior to the `{docs}` block.
"""
immutable DocsBlock <: AbstractExpander end

"""
    DocsNode

Stores the object and related docstring for a single object found in a `{docs}` block. When
a `{docs}` block contains multiple entries then each one is expanded into a separate
[`DocsNode`]({DocsNode}).
"""
immutable DocsNode
    object :: Any
    docs   :: Markdown.MD
end

function expand(::DocsBlock, b::Markdown.Code, env)
    startswith(b.code, "{docs}") || return false

    src  = env.state.src
    dst  = env.state.dst
    meta = env.state.meta
    mod  = get(meta, :CurrentModule, current_module())

    for (ex, str) in parseblock(b.code; skip = 1)
        # find the documented object and it's docstring
        obj = eval(mod, :($(Lapidary).@object($ex)))
        doc = eval(mod, :($(Base).@doc($ex)))
        # error checks
        let n = strip(str),
            f = abspath(src)
            nodocs(doc)              && error("no docs found for '$n' in '$f'.")
            haskey(env.docsmap, obj) && error("docs for '$n' duplicated in '$f'.")
        end
        env.docsmap[obj] = (src, dst, doc, strip(str))
        push!(env.state.blocks, DocsNode(obj, doc))
    end
    true
end

# {index} block
# -------------

"""
    IndexBlock

Expands code blocks where the first line contains `{index}`. Subsequent lines can contain
key/value pairs relevant to the index. Currently `Pages = ["...", ..., "..."]` is supported
for filtering the contents of the index based on source page.

Indexes are used to display links to all the docstrings, generated with `{docs}` blocks, on
any number of pages.
"""
immutable IndexBlock <: AbstractExpander end

"""
    IndexNode

`{index}` code blocks are expanded into this object which is used to store the key/value
pairs needed to build the actual index during the later rendering state.
"""
immutable IndexNode
    dict :: Dict{Symbol, Any}
end

function expand(::IndexBlock, b::Markdown.Code, env)
    startswith(b.code, "{index}") || return false

    src  = env.state.src
    dst  = env.state.dst
    meta = env.state.meta
    mod  = get(meta, :CurrentModule, current_module())
    dict = Dict{Symbol, Any}(:src => src, :dst => dst)

    for (ex, str) in parseblock(b.code; skip = 1)
        isassign(ex) && (dict[ex.args[1]] = eval(mod, ex.args[2]))
    end
    push!(env.state.blocks, IndexNode(dict))
    true
end

# {contents} block
# ----------------

"""
    ContentsBlock

Expands code blocks where the first line contains `{contents}`. Subsequent lines can, like
the `{index}` block, contains key/value pairs. Supported pairs are

    Pages = ["...", ..., "..."]
    Depth = 2

where `Pages` acts the same as for `{index}` and `Depth` limits the header level displayed
in the generated contents.

Contents blocks are used to a display nested list of the headers found in one or more pages.
"""
immutable ContentsBlock <: AbstractExpander end

"""
    ContentsNode

`{contents}` blocks are expanded into these objects, which, like with [`IndexNode`]({ref}),
store the key/value pairs needed to render the contents during the later rendering stage.
"""
immutable ContentsNode
    dict :: Dict{Symbol, Any}
end

function expand(::ContentsBlock, b::Markdown.Code, env)
    startswith(b.code, "{contents}") || return false

    src  = env.state.src
    dst  = env.state.dst
    meta = env.state.meta
    mod  = get(meta, :CurrentModule, current_module())
    dict = Dict{Symbol, Any}(:src => src, :dst => dst)

    for (ex, str) in parseblock(b.code; skip = 1)
        isassign(ex) && (dict[ex.args[1]] = eval(mod, ex.args[2]))
    end
    push!(env.state.blocks, ContentsNode(dict))
    true
end

## walk templates
## ==============

"""
    RunDocTests

Finds all code blocks in an expanded document where the language is set to `julia` and tries
to run them. Any failure will currently just terminate the entire document generation.
"""
immutable RunDocTests end

function (::RunDocTests)(env)
    for each in env.expanded_templates
        walk(Dict(), each.blocks) do code
            isa(code, Markdown.Code) || return true
            doctest(code)
            false
        end
    end
end
log(io, ::RunDocTests) = log(io, "running doctests.")

"""
    CrossReferenceLinks

Finds all `Markdown.Link` elements in an expanded document and tries to find where the link
should point to. Will terminate the entire document generation process when a link cannot
successfully be found.
"""
immutable CrossReferenceLinks end

function (::CrossReferenceLinks)(env)
    for each in env.expanded_templates

        src    = each.src
        dst    = each.dst
        blocks = each.blocks
        meta   = Dict()

        walk(meta, blocks) do link
            isa(link, Markdown.Link) || return true
            if ismatch(r"^{ref(.*)}$", link.url)
                if isa(link.text[1], Markdown.Code)
                    code = link.text[1].code
                    mod  = get(meta, :CurrentModule, current_module())
                    obj  = eval(mod, :($(Lapidary).@object($(parse(code)))))
                    haskey(env.docsmap, obj) || error("no doc for reference '$code' found.")
                    doc_src, doc_dst, docs, docstr = env.docsmap[obj]
                    path   = relpath(doc_dst, dirname(dst))
                    anchor = slugify(string(obj))
                    link.url = string(path, '#', anchor)
                elseif isa(link.text, Vector) && length(link.text) === 1
                    r  = match(r"^{ref#(.+)}$", link.url)
                    id = r === nothing ? sprint(Markdown.plain, Markdown.Paragraph(link.text)) : r[1]
                    id = slugify(id)
                    haskey(env.headers, id) || error("no header ID '$id' found in document.")
                    path = relpath(env.headers[id].dst, dirname(dst))
                    link.url = string(path, '#', id)
                end
            end
            false
        end
    end
end
log(io, ::CrossReferenceLinks) = log(io, "generating cross-reference links.")

"""
    walk(f, meta, element)

Scan a document tree and run function `f` on each `element` that is encountered.
"""
function walk end

# Change to the docstring's defining module if it has one. Change back afterwards.
function walk(f, meta, block::Markdown.MD)
    tmp = get(meta, :CurrentModule, nothing)
    mod = get(block.meta, :module, nothing)
    mod ≡ nothing || (meta[:CurrentModule] = mod)
    f(block) && walk(f, meta, block.content)
    tmp ≡ nothing ? delete!(meta, :CurrentModule) : (meta[:CurrentModule] = tmp)
    nothing
end

function walk(f, meta, block::Vector)
    for each in block
        f(each) && walk(f, meta, each)
    end
end

typealias MDContentElements Union{
    Markdown.BlockQuote,
    Markdown.Paragraph,
    Markdown.MD,
}
walk(f, meta, block::MDContentElements) = f(block) ? walk(f, meta, block.content) : nothing

walk(f, meta, block::DocsNode) = walk(f, meta, block.docs)

walk(f, meta, block::MetaNode) = (merge!(meta, block.dict); nothing)

typealias MDTextElements Union{
    Markdown.Bold,
    Markdown.Footnote,
    Markdown.Header,
    Markdown.Italic,
}
walk(f, meta, block::MDTextElements) = f(block) ? walk(f, meta, block.text)  : nothing

walk(f, meta, block::Markdown.Image) = f(block) ? walk(f, meta, block.alt)   : nothing
walk(f, meta, block::Markdown.Table) = f(block) ? walk(f, meta, block.rows)  : nothing
walk(f, meta, block::Markdown.List)  = f(block) ? walk(f, meta, block.items) : nothing
walk(f, meta, block::Markdown.Link)  = f(block) ? walk(f, meta, block.text)  : nothing

walk(f, meta, block) = (f(block); nothing)

## render document
## ===============

"""
    RenderDocument

Write the contents of the expanded document tree to file. Currently only supports markdown output.
"""
immutable RenderDocument end

function (::RenderDocument)(env)
    for each in env.expanded_templates
        open(each.dst, "w") do io
            render(io, env.mime, each.blocks, env)
        end
    end
end
log(io, ::RenderDocument) = log(io, "rending final document to file.")

function render(io, mime, blocks::Vector, env)
    for each in blocks
        render(io, mime, each, env)
    end
end

render(io, mime, block, env) = (println(io); writemime(io, mime, Markdown.MD(block)); println(io))

function render(io, mime, h::Markdown.Header, env)
    id = env.headermap[h]
    println(io, "\n", "<a id='$id'></a>")
    writemime(io, mime, Markdown.MD(h))
    println(io)
end

function render(io, mime, doc::DocsNode, env)
    id = slugify(string(doc.object))
    println(io, "\n", "<a id='$id' href='#$id'>#</a>")
    println(io, "**", doccat(doc.object), "**", "\n")
    writemime(io, mime, doc.docs)
    println(io, "\n", "---")
end

function render(io, mime, index::IndexNode, env)
    pages = get!(index.dict, :Pages, [])
    links = []
    for (obj, (src, dst, markdown, docstr)) in env.docsmap
        path = relpath(dst, dirname(index.dict[:dst]))
        if isempty(pages) || any(x -> startswith(path, x), pages)
            push!(links, (docstr, string(path, '#', slugify(string(obj)))))
        end
    end
    sort!(links, by = t -> t[2])
    for (docstr, path) in links
        println(io, "- ", "[`", docstr, "`](", path, ")")
    end
end

function render(io, mime, contents::ContentsNode, env)
    pages = get(contents.dict, :Pages, [])
    depth = get(contents.dict, :Depth, 2)
    links = []
    for (id, headerpath) in env.headers
        path = relpath(headerpath.dst, dirname(contents.dict[:dst]))
        if isempty(pages) || any(x -> startswith(path, x), pages)
            if header_level(headerpath.ast) ≤ depth
                push!(links, (headerpath.nth, headerpath.ast, string(path, '#', id)))
            end
        end
    end
    sort!(links, by = t -> t[1])
    for (counter, header, path) in links
        link = Markdown.Link(header.text, path)
        print(io, "    "^(header_level(header) - 1), "- ")
        Markdown.plaininline(io, link)
        println(io)
    end
end

render(io, mime, meta::MetaNode, env) = nothing

# utilities
# =========

"""
    log

Print a formatted message to `STDOUT`. Each document "stage" type must provide an implementation
of this function.
"""
function log end

log(T) = log(STDOUT, T)
log(io, msg::AbstractString) = print_with_color(:magenta, io, string("LAPIDARY: ", msg, "\n"))

"""
    process(env, stages...)

For each stage in `stages` execute stage with the given `env` as it's argument.
"""
process(env::Env, stages...)  = process(stages, env)
process(stages::Tuple,   env) = (car(stages)(env); log(car(stages)); process(cdr(stages), env))
process(stages::Tuple{}, env) = nothing


"""
    car(x)

Head element of the `Tuple` `x`. See also [`cdr`]({ref}).
"""
@inline    car(x::Tuple) = _car(x...)
@inline   _car(h, t...)  = h
@noinline _car()         = error("empty tuple.")

"""
    cdr(x)

Tail elements of the `Tuple` `x`. See also [`car`]({ref}).
"""
@inline    cdr(x::Tuple) = _cdr(x...)
@inline   _cdr(h, t...)  = t
@noinline _cdr()         = error("empty tuple.")


"""
    currentdir()

Returns the current source directory. When `isinteractive() ≡ true` then the present working
directory, `pwd()` is returned instead.
"""
function currentdir()
    d = Base.source_dir()
    d === nothing ? pwd() : d
end

"""
    assetsdir()

Directory containing Lapidary asset files.
"""
assetsdir() = normpath(joinpath(dirname(@__FILE__), "..", "assets"))

"""
    parseblock(code; skip = 0)

Returns an array of (expression, string) tuples for each complete toplevel expression from
`code`. The `skip` keyword argument will drop the provided number of leading lines.
"""
function parseblock(code; skip = 0)
    code = string(code, '\n')
    code = last(split(code, '\n', limit = skip + 1))
    results, cursor = [], 1
    while cursor < length(code)
        ex, ncursor = parse(code, cursor)
        push!(results, (ex, code[cursor:ncursor-1]))
        cursor = ncursor
    end
    results
end

isassign(x) = isexpr(x, :(=), 2) && isa(x.args[1], Symbol)

"""
    @object(x)

Returns a normalised object that can be used to track which objects from the Julia docsystem
have been spliced into the current document tree.
"""
macro object(x)
    haskey(Docs.keywords, x) ? quot(x) :
    isexpr(x, :call)         ? findmethod(x) :
    Docs.isvar(x)            ? :(Docs.@var($(esc(x)))) :
    esc(x)
end
findmethod(x) = Expr(:tuple, esc(Docs.namify(x)), esc(Docs.signature(x)))

"""
    nodocs(x)

Does the document returned from the docsystem contain any useful documentation.
"""
nodocs(x) = contains(stringmime("text/plain", x), "No documentation found.")

"""
    slugify(s)

Slugify a string `s` by removing special characters. Used in the url generation process.
"""
function slugify(s)
    s = strip(lowercase(s))
    s = replace(s, r"\s+", "-")
    s = replace(s, r"&", "-and-")
    s = replace(s, r"[^\w\-]+", "")
    s = strip(replace(s, r"\-\-+", "-"), '-')
end

"""
    doctest(source)

Try to run the Julia source code found in `source`.
"""
function doctest(source::Markdown.Code)
    if source.language == "julia"
        sandbox = Module()
        if ismatch(r"^julia> "m, source.code) # test is a REPL-type.
            parts = split(source.code, "\njulia> ")
            for part in parts
                # each part should be a single complete expression followed by a result,
                # which may not be complete, or actually valid julia code at all.
                part   = replace(part, "julia> ", "", 1)
                cursor = 1
                expr, ncursor = parse(part, cursor)
                result, backtrace = nothing, nothing
                try
                    result = eval(sandbox, expr)
                    eval(sandbox, :(ans = $(result)))
                catch err
                    result, backtrace = err, catch_backtrace()
                end
                result_text = strip(part[ncursor:end], '\n')
                show_result = !endswith(strip(part[cursor:ncursor-1]), ";")
                # Print out the calculated values and backtrace.
                buf = IOBuffer()
                print_response(buf, result, backtrace, show_result)
                @assert startswith(takebuf_string(buf), result_text)
            end
        elseif ismatch(r"^# output:$"m, source.code) # test is a script-type code block.
            parts = split(source.code, "\n# output:\n", limit = 2)
            @assert length(parts) == 2
            code, result_text = parts
            result, backtrace = nothing, nothing
            try
                for (ex, str) in parseblock(code)
                    result = eval(sandbox, ex)
                end
            catch err
                result, backtrace = err, catch_backtrace()
            end
            result_text = strip(result_text, '\n')
            buf = IOBuffer()
            print_response(buf, result, backtrace, true)
            @assert startswith(takebuf_string(buf), result_text)
        end
    end
end
function print_response(buf, result, backtrace, show_result)
    if backtrace ≡ nothing
        if result ≢ nothing && show_result
            show(buf, result)
        end
    else
        print(buf, "    {throws ", typeof(result), "}")
    end
end

header_level{N}(::Markdown.Header{N}) = N

doccat(x::Docs.Binding) = startswith(string(x.var), "@") ? "Macro" : doccat(getfield(x.mod, x.var))
doccat(x::Tuple)        = "Method"
doccat(x::Function)     = "Function"
doccat(x::DataType)     = "Type"
doccat(x::Module)       = "Module"
doccat(other)           = "Constant"

end