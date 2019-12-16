" consts
let s:buffer_name = '<context.vim>'

" cached
let s:ellipsis  = repeat(g:context_ellipsis_char, 3)
let s:ellipsis5 = repeat(g:context_ellipsis_char, 5)

" state
let s:resize_level = 0 " for decreasing window height based on scrolling
let s:activated = 0
let s:last_winnr = -1
let s:last_bufnr = -1
let s:last_top_line = -10
let s:min_height = 0
let s:padding = 0
let s:ignore_autocmd = 0
let s:log_indent = 0


" call this on VimEnter to activate the plugin
function! context#activate() abort
    " for some reason there seems to be a race when we try to show context of
    " one buffer before another one gets opened in startup
    " to avoid that we wait for startup to be finished
    let s:activated = 1
    call context#update(0, 'VimEnter')
endfunction

function! context#enable() abort
    let g:context_enabled = 1
    call context#update(1, 0)
endfunction

function! context#disable() abort
    let g:context_enabled = 0

    silent! wincmd P " jump to new preview window
    if &previewwindow
        let bufname = bufname('%')
        wincmd p " jump back
        if bufname == s:buffer_name
            " if current preview window is context, close it
            pclose
        endif
    endif
endfunction

function! context#toggle() abort
    if g:context_enabled
        call context#disable()
    else
        call context#enable()
    endif
endfunction


function! context#update(force_resize, autocmd) abort
    if !g:context_enabled || !s:activated
        " call s:echof(' disabled')
        return
    endif

    if &previewwindow
        " no context of preview windows (which we use to display context)
        " call s:echof(' abort preview')
        return
    endif

    if mode() != 'n'
        " call s:echof(' abort mode')
        return
    endif

    if type(a:autocmd) == type('') && s:ignore_autocmd
        " ignore nested calls from auto commands
        " call s:echof(' abort from autocmd')
        return
    endif

    call s:echof('> update', a:force_resize, a:autocmd)

    let s:ignore_autocmd = 1
    let s:log_indent += 1
    call s:update_context(1, a:force_resize)
    let s:log_indent -= 1
    let s:ignore_autocmd = 0
endfunction

function! context#update_padding(autocmd) abort
    " call s:echof('> update_padding', a:autocmd)
    if !g:context_enabled
        return
    endif

    if &previewwindow
        " no context of preview windows (which we use to display context)
        " call s:echof(' abort preview')
        return
    endif

    if mode() != 'n'
        " call s:echof(' abort mode')
        return
    endif

    let padding = wincol() - virtcol('.')

    if s:padding == padding
        " call s:echof(' abort same padding', s:padding, padding)
        return
    endif

    silent! wincmd P
    if !&previewwindow
        " call s:echof(' abort no preview')
        return
    endif

    if bufname('%') != s:buffer_name
        " call s:echof(' abort different preview')
        wincmd p
        return
    endif

    " call s:echof(' update padding', padding, a:autocmd)
    call s:set_padding(padding)
    wincmd p
endfunction


" this function actually updates the context and calls itself until it stabilizes
function! s:update_context(allow_resize, force_resize) abort
    call s:echof('> update_context', a:allow_resize, a:force_resize)

    let winnr = winnr()
    let bufnr = bufnr('%')
    let current_line = line('w0')

    " adjust min window height based on scroll amount
    if a:force_resize
        let s:min_height = 0
    elseif a:allow_resize && s:last_winnr == winnr && s:last_top_line != current_line
        let diff = abs(s:last_top_line - current_line)
        if diff == 1
            " slowly decrease min height if moving line by line
            let s:resize_level += g:context_resize_linewise
        else
            " quicker if moving multiple lines (^U/^D: decrease by one line)
            let s:resize_level += g:context_resize_scroll / &scroll * diff
        endif
        let t = float2nr(s:resize_level)
        let s:resize_level -= t
        let s:min_height -= t
    endif

    if !a:force_resize && s:last_bufnr == bufnr && s:last_top_line == current_line
        call s:echof(' abort same buf and top line', bufnr, current_line)
        return
    endif

    let s:last_winnr = winnr
    let s:last_bufnr = bufnr
    let s:last_top_line = current_line

    " find first line above (hidden) which isn't empty
    let s:hidden = s:make_line(0, 0, "") " in case there is none
    let current_line = s:last_top_line - 1 " first hidden line
    while current_line > 0
        let line = getline(current_line)
        if s:skip_line(line)
            let current_line -= 1
            continue
        endif

        let s:hidden = s:make_line(current_line, indent(current_line), line)
        break
    endwhile

    " find line downwards which isn't empty
    let max_line = line('$')
    let current_indent = 0 " in case there are no nonempty lines below
    let current_line = s:last_top_line
    while current_line <= max_line
        let line = getline(current_line)
        if s:skip_line(line)
            let current_line += 1
            continue
        endif

        let current_indent = indent(current_line)
        break
    endwhile

    " collect all context lines
    let context = {}
    let line_count = 0
    let current_line = s:last_top_line
    while current_line > 1
        let allow_same = 0

        " if line starts with closing brace: jump to matching opening one and add it to context
        " also for other prefixes to show the if which belongs to an else etc.
        if s:extend_line(line)
            let allow_same = 1
        elseif current_indent == 0
            break
        endif

        " search for line with same indent (or less)
        while current_line > 1
            let current_line -= 1
            let line = getline(current_line)
            if s:skip_line(line)
                continue " ignore empty lines
            endif

            let indent = indent(current_line)
            if indent < current_indent || allow_same && indent == current_indent
                if !has_key(context, indent)
                    let context[indent] = []
                endif

                call insert(context[indent], s:make_line(current_line, indent, line), 0)
                let line_count += 1
                let current_indent = indent

                if s:hidden.number == current_line
                    " don't show ellipsis if hidden line is part of context
                    let s:hidden = s:make_line(0, 0, "")
                endif
                break
            endif
        endwhile
    endwhile

    " limit context per intend
    let diff_want = line_count - s:min_height
    let lines = []
    " no more than five lines per indent
    for indent in sort(keys(context), 'N')
        let [context[indent], diff_want] = s:join(context[indent], diff_want)
        let [context[indent], diff_want] = s:limit(context[indent], diff_want, indent)
        call extend(lines, context[indent])
    endfor

    if len(lines) == 0
        " don't show ellipsis if context is empty
        let s:hidden = s:make_line(0, 0, "")
    endif

    " limit total context
    let max = g:context_max_height
    if len(lines) > max
        let indent1 = lines[max/2].indent
        let indent2 = lines[-(max-1)/2].indent
        let ellipsis = repeat(g:context_ellipsis_char, max([indent2 - indent1, 3]))
        let ellipsis_line = s:make_line(0, indent1, repeat(' ', indent1) . ellipsis)
        call remove(lines, max/2, -(max+1)/2)
        call insert(lines, ellipsis_line, max/2)
    endif

    let s:log_indent += 1
    call s:show_in_preview(lines)
    let s:log_indent -= 1
    " call again until it stabilizes
    " disallow resizing to make sure it will eventually
    let s:log_indent += 1
    call s:update_context(0, 0)
    let s:log_indent -= 1
endfunction

" https://vi.stackexchange.com/questions/19056/how-to-create-preview-window-to-display-a-string
function! s:open_preview() abort
    call s:echof('> open_preview')
    let settings = '+setlocal'      .
                \ ' buftype=nofile' .
                \ ' modifiable'     .
                \ ' nobuflisted'    .
                \ ' nocursorline'   .
                \ ' nonumber'       .
                \ ' noswapfile'     .
                \ ' nowrap'         .
                \ ''
    execute 'silent! aboveleft pedit' escape(settings, ' ') s:buffer_name
endfunction

function! s:show_in_preview(lines) abort
    call s:echof('> show_in_preview', len(a:lines))

    pclose
    if len(a:lines) == 0
        return
    endif

    if s:min_height < len(a:lines)
        let s:min_height = len(a:lines)
    endif

    let filetype = &filetype
    let tabstop  = &tabstop
    let padding  = wincol() - virtcol('.')

    " based on https://stackoverflow.com/questions/13707052/quickfix-preview-window-resizing
    silent! wincmd P " jump to preview, but don't show error
    if &previewwindow
        if bufname('%') == s:buffer_name
            " reuse existing preview window
            call s:echof(' reuse')
            silent %delete _
        elseif s:min_height == 0
            " nothing to do
            call s:echof(' not ours')
            wincmd p " jump back
            return
        else
            call s:echof(' take over')
            let s:log_indent += 1
            call s:open_preview()
            let s:log_indent -= 1
        endif

    elseif s:min_height == 0
        " nothing to do
        call s:echof(' none')
        return
    else
        call s:echof(' open new')
        let s:log_indent += 1
        call s:open_preview()
        let s:log_indent -= 1

        " try to jump to new preview window
        silent! wincmd P
        if !&previewwindow
            " NOTE: apparently this can fail with E242, see #6
            " in that case just silently abort
            call s:echof(' no preview window')
            return
        endif
    endif

    while len(a:lines) < s:min_height
        call add(a:lines, s:make_line(0, 0, ""))
    endwhile

    " NOTE: this overwrites a:lines, but we don't need it anymore
    call map(a:lines, function('s:display_line'))
    silent 0put =a:lines " paste lines
    1                    " and jump to first line

    execute 'setlocal filetype=' . filetype
    execute 'setlocal tabstop='  . tabstop
    call s:set_padding(padding)

    " resize window
    execute 'resize' s:min_height

    wincmd p " jump back
endfunction

" NOTE: this function updates the statusline too, as it depends on the padding
function! s:set_padding(padding) abort
    let padding = a:padding
    if padding >= 0
        execute 'setlocal foldcolumn=' . padding
        let s:padding = padding
    else
        " padding can be negative if cursor was on the wrapped part of a wrapped line
        " in that case don't try to apply it, but still update the statusline
        " using the last known padding value
        let padding = s:padding
    endif

    let statusline = '%=' . s:buffer_name . ' ' " trailing space for padding
    if s:hidden.number > 0
        let statusline = repeat(' ', padding + s:hidden.indent) . s:ellipsis . statusline
    endif
    execute 'setlocal statusline=' . escape(statusline, ' ')
endfunction


function! s:join(lines, diff_want) abort
    let diff_want = a:diff_want

    " only works with at least 3 parts, so disable otherwise
    if g:context_max_join_parts < 3
        return [a:lines, a:diff_want]
    endif

    " call s:echof('> join', len(a:lines), diff_want)
    let pending = [] " lines which might be joined with previous
    let joined = a:lines[:0] " start with first line
    for line in a:lines[1:]
        if s:join_line(line.text)
            " add lines without word characters to pending list
            call add(pending, line)
            let diff_want -= 1
            continue
        endif

        " don't join lines with word characters
        " but first join pending lines to previous output line
        let joined[-1] = s:join_pending(joined[-1], pending)
        let pending = []
        call add(joined, line)
    endfor

    " join remaining pending lines to last
    let joined[-1] = s:join_pending(joined[-1], pending)
    return [joined, diff_want]
endfunction

function! s:join_pending(base, pending) abort
    " call s:echof('> join_pending', len(a:pending))
    if len(a:pending) == 0
        return a:base
    endif

    let max = g:context_max_join_parts
    if len(a:pending) > max-1
        call remove(a:pending, (max-1)/2-1, -max/2-1)
        call insert(a:pending, s:make_line(0, 0, ''), (max-1)/2-1) " middle marker
    endif

    let joined = a:base
    for line in a:pending
        let joined.text .= ' '
        if line.number == 0
            " this is the middle marker, use long ellipsis
            let joined.text .= s:ellipsis5
        elseif joined.number != 0 && line.number != joined.number + 1
            " not after middle marker and there are lines in between: show ellipsis
            let joined.text .= s:ellipsis . ' '
        endif

        let joined.text .= s:trim(line.text)
        let joined.number = line.number
    endfor

    return joined
endfunction

function! s:limit(lines, diff_want, indent) abort
    " call s:echof('> limit', a:indent, len(a:lines), a:diff_want)
    if a:diff_want <= 0
        return [a:lines, a:diff_want]
    endif

    let max = g:context_max_per_indent
    if len(a:lines) <= max
        return [a:lines, a:diff_want]
    endif

    let diff = len(a:lines) - max
    if diff > a:diff_want
        let max += diff
    endif

    let limited = a:lines[: max/2-1]
    call add(limited, s:make_line(0, a:indent, repeat(' ', a:indent) . s:ellipsis))
    call extend(limited, a:lines[-(max-1)/2 :])
    return [limited, a:diff_want - (len(a:lines) - max)]
endif
endfunction

function! s:make_line(number, indent, text) abort
    return {
                \ 'number': a:number,
                \ 'indent': a:indent,
                \ 'text':   a:text,
                \ }
endfunction

function! s:display_line(index, line) abort
    return a:line.text

    " NOTE: comment out the line above to include this debug info
    let n = &columns - 25 - strchars(s:trim(a:line.text)) - a:line.indent
    return printf("%s%s // %2d n:%5d i:%2d", a:line.text, repeat(' ', n), a:index+1, a:line.number, a:line.indent)
endfunction

function! s:extend_line(line) abort
    return a:line =~ g:context_extend_regex
endfunction

function! s:skip_line(line) abort
    return a:line =~ g:context_skip_regex
endfunction

function! s:join_line(line) abort
    return a:line =~ g:context_join_regex
endfunction

function s:trim(string) abort
    return substitute(a:string, '^\s*', '', '')
endfunction

" debug logging, set g:context_logfile to activate
function! s:echof(...) abort
    let args = join(a:000)
    let args = substitute(args, "'", '"', "g")
    let message = repeat(' ', s:log_indent) . args

    " echom message
    if exists('g:context_logfile')
        execute "silent! !echo '" . message . "' >>" g:context_logfile
    endif
endfunction
