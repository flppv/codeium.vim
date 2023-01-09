let s:codeium_version = '1.0.0'
let s:ide = 'jetbrains'

let s:server_port = v:null
let s:server_job = v:null

function! s:OnExit(result, status, on_complete_cb) abort
  let did_close = has_key(a:result, 'closed')
  if did_close
    call remove(a:result, 'closed')
    call a:on_complete_cb(a:result.out, a:status)
  else
    " Wait until we receive OnClose, and call on_complete_cb then.
    let a:result.exit_status = a:status
  endif
endfunction

function! s:OnClose(result, on_complete_cb) abort
  let did_exit = has_key(a:result, 'exit_status')
  if did_exit
    call a:on_complete_cb(a:result.out, a:result.exit_status)
  else
    " Wait until we receive OnExit, and call on_complete_cb then.
    let a:result.closed = v:true
  endif
endfunction

function! s:NoopCallback(...) abort
endfunction

function! codeium#server#RequestMetadata() abort
  return {
        \ "api_key": codeium#command#ApiKey(),
        \ "ide_name":  s:ide,
        \ "extension_version":  s:codeium_version,
        \ }
endfunction

function! codeium#server#Request(type, data, ...) abort
  if s:server_port is# v:null
    throw "Server port has not been properly initialized."
  endif
  let uri = 'http://localhost:' . s:server_port . 
      \ '/exa.language_server_pb.LanguageServerService/' . a:type
  let args = [
              \ 'curl', uri,
              \ '--header', 'Content-Type: application/json',
              \ '--data', json_encode(a:data)
              \ ]
  let result = {"out": []}
  let ExitCallback = a:0 && !empty(a:1) ? a:1 : function('s:NoopCallback')
  if has('nvim')
    return jobstart(args, {
                \ 'on_stdout': { channel, data, t -> add(result.out, join(data, "\n")) },
                \ 'on_exit': { job, status, t -> ExitCallback(result.out, status) },
                \ })
  else
    return job_start(args, {
                \ 'out_mode': 'raw',
                \ 'out_cb': { channel, data -> add(result.out, data) },
                \ 'exit_cb': { job, status -> s:OnExit(result, status, ExitCallback) },
                \ 'close_cb': { channel -> s:OnClose(result, ExitCallback) }
                \ })
  endif
endfunction

function! s:FindPort(dir, timer) abort
  let time = localtime()
  for name in readdir(a:dir)
    let path = a:dir . '/' . name
    if time - getftime(path) <= 1 && getftype(path) == "file"
      call codeium#log#Info("Found port: " . name)
      let s:server_port = name
      call timer_stop(a:timer)
      break
    endif
  endfor
endfunction

function! s:SendHeartbeat(timer) abort
  try
    call codeium#server#Request('Heartbeat', {'metadata': codeium#server#RequestMetadata()})
  catch
    call codeium#log#Exception()
  endtry
endfunction

function! codeium#server#Start() abort
  let os = substitute(system('uname'), '\n', '', '')
  let arch = substitute(system('uname -m'), '\n', '', '')
  let is_arm = stridx(arch, "arm") == 0 || stridx(arch, "aarch64") == 0

  if os == 'Linux' && is_arm
    let bin_suffix = "linux_arm"
  elseif os == 'Linux'
    let bin_suffix = "linux_x64"
  elseif os == 'Darwin' && is_arm
    let bin_suffix = "macos_arm"
  elseif os == 'Darwin'
    let bin_suffix = "macos_x64"
  else
    let bin_suffix = "windows_x64.exe"
  endif

  let s:root = expand('<sfile>:h:h')
  let bin_dir = s:root . "/bin"
  let bin = bin_dir . "/language_server_" . bin_suffix

  if !isdirectory(bin_dir)
    call mkdir(bin_dir)
  endif

  if empty(glob(bin))
    let url = 'https://github.com/Exafunction/codeium/releases/download/language-server-v1.1.14/language_server_' . bin_suffix . '.gz'
    call system('curl -Lo ' . bin . '.gz' . ' ' . url)
    call system('gzip -d ' . bin . '.gz')
    call system('chmod +x ' . bin)
    if empty(glob(bin))
      call codeium#log#Error("Failed to download language server binary.")
      return ''
    endif
  endif

  let config = get(g:, "codeium_server_config", {})
  let manager_dir = tempname() . '/codeium/manager'
  call mkdir(manager_dir, "p")

  let args = [
        \ bin,
        \ "--api_server_host", config->get("api_host", "server.codeium.com"),
        \ "--api_server_port", config->get("api_port", "443"),
        \ "--manager_dir", manager_dir
        \ ]

  call codeium#log#Info("Launching server with manager_dir " . manager_dir)
  if has('nvim')
    let s:server_job = jobstart(args, {
                \ 'on_stderr': { channel, data, t -> codeium#log#Info("[SERVER] " . join(data, "\n")) },
                \ })
  else
    let s:server_job = job_start(args, {
                \ 'out_mode': 'raw',
                \ 'err_cb': { channel, data -> codeium#log#Info("[SERVER] " . data) },
                \ })
  endif
  call timer_start(500, function('s:FindPort', [manager_dir]), {'repeat': -1})
  call timer_start(5000, function('s:SendHeartbeat', []), {'repeat': -1})
endfunction