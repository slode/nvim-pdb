sign define PdbBreakpoint text=●
sign define PdbCurrentLine text=⇒

let s:breakpoints = {}
let s:max_breakpoint_sign_id = 0

let s:PdbRunning = vimexpect#State([
      \ ['\v^\> ([^(]+)\((\d+)\)', 'jump'],
      \ ['c\s*$', 'running'],
      \ ['cont\s*$', 'running'],
      \ ['continue\s*$', 'running'],
      \ ])

function s:PdbRunning.running(...)
  let self._running = 1
endfunction

function s:PdbRunning.jump(file, line, ...)
  let self._running = 0
  if tabpagenr() != self._tab
    " Don't jump if we are not in the debugger tab
    return
  endif
  let window = winnr()
  exe self._jump_window 'wincmd w'

  let self._current_buf = bufnr('%')
  let target_buf = bufnr(a:file, 1)
  if bufnr('%') != target_buf
    exe 'buffer ' target_buf
    let self._current_buf = target_buf
  endif
  exe ':' a:line
  let self._current_line = a:line
  exe window 'wincmd w'
  call self.update_current_line_sign(1)
endfunction

let s:Pdb = {}

function s:Pdb.on_exit(job_id, _data, event)
  call self.kill()
endfunction

function s:Pdb.kill()
  tunmap <f8>
  tunmap <f10>
  tunmap <f11>
  tunmap <f12>
  try
    call jobstop(self._client_id)
  catch
  endtry
  call self.update_current_line_sign(0)
  exe 'bd! '.self._client_buf
  "exe 'tabnext '.self._tab
  tabclose
  echo "Finished debugging [" . self._cmd . "]"
  unlet g:pdb
endfunction


function! s:Pdb.send(data)
  try
    call chansend(self._client_id, a:data."\<cr>")
  catch
    call self.kill()
  endtry
endfunction


function! s:Pdb.update_current_line_sign(add)
  " to avoid flicker when removing/adding the sign column(due to the change in
  " line width), we switch ids for the line sign and only remove the old line
  " sign after marking the new one
  let old_line_sign_id = get(self, '_line_sign_id', 4999)
  let self._line_sign_id = old_line_sign_id == 4999 ? 4998 : 4999
  if a:add && self._current_line != -1 && self._current_buf != -1
    exe 'sign place '.self._line_sign_id.' name=PdbCurrentLine line='
          \.self._current_line.' buffer='.self._current_buf
  endif
  exe 'sign unplace '.old_line_sign_id
endfunction

function! s:Spawn(client_cmd)
  if exists('g:pdb')
    throw 'Pdb already running'
  endif

  let pdb = vimexpect#Parser(s:PdbRunning, copy(s:Pdb))
  " window number that will be displaying the current file
  let pdb._jump_window = 1
  let pdb._current_buf = -1
  let pdb._current_line = -1
  let pdb._has_breakpoints = 0 
  let pdb._cmd = a:client_cmd
  let pdb._running = 0

  " Create new tab for the debugging view
  tabnew
  let pdb._tab = tabpagenr()

  " create horizontal split to display the current file
  sp

  " go to the bottom window and spawn pdb client
  wincmd j
  enew | let pdb._client_id = termopen(expand(a:client_cmd), pdb) | set ft=python
  let pdb._client_buf = bufnr('%')

  tnoremap <silent> <f8> <c-\><c-n>:PdbContinue<cr>i
  tnoremap <silent> <f10> <c-\><c-n>:PdbNext<cr>i
  tnoremap <silent> <f11> <c-\><c-n>:PdbStep<cr>i
  tnoremap <silent> <f12> <c-\><c-n>:PdbFinish<cr>i

  " go to the window that displays the current file
  exe pdb._jump_window 'wincmd w'
  let g:pdb = pdb
endfunction

function! s:ToggleBreak()
  let file_name = bufname('%')
  let file_breakpoints = get(s:breakpoints, file_name, {})
  let linenr = line('.')
  if has_key(file_breakpoints, linenr)
    call remove(file_breakpoints, linenr)
  else
    let file_breakpoints[linenr] = 1
  endif
  let s:breakpoints[file_name] = file_breakpoints
  call s:RefreshBreakpointSigns()
  call s:RefreshBreakpoints()
endfunction


function! s:ClearBreak()
  let s:breakpoints = {}
  call s:RefreshBreakpointSigns()
  call s:RefreshBreakpoints()
endfunction


function! s:RefreshBreakpointSigns()
  let buf = bufnr('%')
  let i = 5000
  while i <= s:max_breakpoint_sign_id
    exe 'sign unplace '.i
    let i += 1
  endwhile
  let s:max_breakpoint_sign_id = 0
  let id = 5000
  for linenr in keys(get(s:breakpoints, bufname('%'), {}))
    exe 'sign place '.id.' name=PdbBreakpoint line='.linenr.' buffer='.buf
    let s:max_breakpoint_sign_id = id
    let id += 1
  endfor
endfunction


function! s:RefreshBreakpoints()
  if !exists('g:pdb')
    return
  endif

  call s:Interrupt()

  if g:pdb._has_breakpoints
    call g:pdb.send('clear')
    call g:pdb.send('y')
  endif

  let g:pdb._has_breakpoints = 0
  for [file, breakpoints] in items(s:breakpoints)
    for linenr in keys(breakpoints)
      let g:pdb._has_breakpoints = 1
      call g:pdb.send('break '.file.':'.linenr)
    endfor
  endfor
endfunction

function! s:PrintBreakpoints()
  if !exists('g:pdb')
    return
  endif

  let g:pdb._has_breakpoints = 0
  for [file, breakpoints] in items(s:breakpoints)
    for linenr in keys(breakpoints)
      echo file . ":" . linenr
    endfor
  endfor
endfunction



function! s:GetExpression(...) range
  let [lnum1, col1] = getpos("'<")[1:2]
  let [lnum2, col2] = getpos("'>")[1:2]
  let lines = getline(lnum1, lnum2)
  let lines[-1] = lines[-1][:col2 - 1]
  let lines[0] = lines[0][col1 - 1:]
  return join(lines, " ")
endfunction


function! s:Send(data)
  if !exists('g:pdb')
    throw 'Pdb is not running'
  endif
  call g:pdb.send(a:data)
endfunction


function! s:Eval(expr)
  call s:Send(printf('%s', a:expr))
endfunction


function! s:Watch(expr)
  let expr = a:expr

  call s:Eval(expr)
  call s:Send('display *$')
endfunction


function! s:Interrupt()
  if !exists('g:pdb')
    throw 'Pdb is not running'
  endif
  if g:pdb._running
    call jobsend(g:pdb._client_id, "\<c-c>")
    sleep 2
    let g:pdb._running = 0
  endif
endfunction

function! s:Finish()
  if !exists('g:pdb')
    throw 'Pdb is not running'
  endif
  call s:Interrupt()
  call jobsend(g:pdb._client_id, "\<c-d>\<cr>")
endfunction

function! s:Kill()
  if !exists('g:pdb')
    throw 'Pdb is not running'
  endif
  call g:pdb.kill()
endfunction

function! s:Continue()
  if !exists('g:pdb')
    throw 'Pdb is not running'
  endif
  if g:pdb._running
    call s:Interrupt()
  else
    let g:pdb._running = 1
    call s:Send("c")
  endif
endfunction


command! -nargs=1 -complete=shellcmd Pdb call s:Spawn(<q-args>)
command! PdbStop call s:Kill()
command! PdbToggleBreakpoint call s:ToggleBreak()
command! PdbPrintBreakpoint call s:PrintBreakpoints()
command! PdbClearBreakpoints call s:ClearBreak()
command! PdbContinue call s:Continue()
command! PdbNext call s:Send("n")
command! PdbStep call s:Send("s")
command! PdbFinish call s:Finish()
command! PdbFrameUp call s:Send("up")
command! PdbFrameDown call s:Send("down")
command! PdbInterrupt call s:Interrupt()
command! PdbEvalWord call s:Eval(expand('<cword>'))
command! -range PdbEvalRange call s:Eval(s:GetExpression(<f-args>))
command! PdbWatchWord call s:Watch(expand('<cword>')
command! -range PdbWatchRange call s:Watch(s:GetExpression(<f-args>))


nnoremap <silent> <f8> :PdbContinue<cr>
nnoremap <silent> <f10> :PdbNext<cr>
nnoremap <silent> <f11> :PdbStep<cr>
nnoremap <silent> <f12> :PdbFinish<cr>
nnoremap <silent> <c-b> :PdbToggleBreakpoint<cr>
nnoremap <silent> <c-pageup> :PdbFrameUp<cr>
nnoremap <silent> <c-pagedown> :PdbFrameDown<cr>
nnoremap <silent> <f9> :PdbEvalWord<cr>
vnoremap <silent> <f9> :PdbEvalRange<cr>
nnoremap <silent> <c-f9> :PdbWatchWord<cr>
vnoremap <silent> <c-f9> :PdbWatchRange<cr>
