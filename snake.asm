; Snake Game in x86-64 NASM Assembly for Linux
; Compile with: nasm -f elf64 snake.asm -o snake.o && ld snake.o -o snake

section .data
    ; Game constants
    BOARD_WIDTH     equ 15
    BOARD_HEIGHT    equ 17
    MAX_SNAKE_LEN   equ 255
    GAME_SPEED      equ 100000  ; microseconds (100ms = 10 FPS)
    
    ; ASCII characters
    SNAKE_HEAD      db 0x07    ; Bell character (displays as ●)
    SNAKE_BODY      db 0xDB    ; Block character (█)
    FOOD_CHAR       db 0x04    ; Diamond character (♦)
    WALL_CHAR       db '#'
    EMPTY_CHAR      db ' '
    
    ; ANSI escape sequences
    clear_screen    db 27, '[2J', 27, '[H', 0
    hide_cursor     db 27, '[?25l', 0
    show_cursor     db 27, '[?25h', 0
    reset_color     db 27, '[0m', 0
    red_color       db 27, '[31m', 0
    green_color     db 27, '[32m', 0
    yellow_color    db 27, '[33m', 0
    blue_color      db 27, '[34m', 0
    magenta_color   db 27, '[35m', 0
    cyan_color      db 27, '[36m', 0
    white_color     db 27, '[37m', 0
    
    ; Game messages
    title_msg       db 27, '[1;1H', 27, '[36m', 'SNAKE GAME', 27, '[0m', 10, 0
    score_msg       db 27, '[2;1H', 'Score: ', 0
    high_score_msg  db 27, '[3;1H', 'High Score: ', 0
    game_over_msg   db 27, '[10;5H', 27, '[31m', 'GAME OVER!', 27, '[0m', 10, 0
    restart_msg     db 27, '[12;5H', 'Press R to restart, Q to quit', 10, 0
    controls_msg    db 27, '[19;1H', 'Controls: WASD or Arrow Keys, Q to quit', 0
    
    ; File operations
    highscore_file  db '.snake_highscore', 0
    home_env        db 'HOME', 0
    
    ; Terminal settings storage
    orig_termios    times 60 db 0  ; struct termios is ~60 bytes
    
section .bss
    ; Game state
    snake_x         resb MAX_SNAKE_LEN
    snake_y         resb MAX_SNAKE_LEN
    snake_length    resq 1
    snake_dir_x     resq 1
    snake_dir_y     resq 1
    food_x          resq 1
    food_y          resq 1
    score           resq 1
    high_score      resq 1
    game_running    resq 1
    
    ; Input buffer
    input_char      resb 1
    
    ; File path buffer
    highscore_path  resb 256
    
    ; Number conversion buffer
    num_buffer      resb 16
    
    ; Random seed
    rand_seed       resq 1

section .text
    global _start

_start:
    ; Initialize random seed with current time
    mov rax, 96        ; sys_gettimeofday
    sub rsp, 16        ; allocate space for timeval struct
    mov rdi, rsp       ; ptr to timeval
    xor rsi, rsi       ; timezone = NULL
    syscall
    mov rax, [rsp]     ; get seconds
    mov [rand_seed], rax
    add rsp, 16        ; cleanup stack
    
    ; Setup signal handlers
    call setup_signals
    
    ; Setup terminal
    call setup_terminal
    
    ; Load high score
    call load_high_score
    
    ; Initialize game
    call init_game
    
    ; Main game loop
game_loop:
    call clear_screen_func
    call draw_game
    call handle_input
    call update_game
    call sleep_func
    
    cmp qword [game_running], 0
    jne game_loop
    
    ; Game over screen
game_over_screen:
    call clear_screen_func
    call draw_game_over
    
wait_restart:
    call get_input
    cmp al, 'r'
    je restart_game
    cmp al, 'R'
    je restart_game
    cmp al, 'q'
    je exit_game
    cmp al, 'Q'
    je exit_game
    jmp wait_restart
    
restart_game:
    call init_game
    jmp game_loop
    
exit_game:
    call cleanup_terminal
    mov rax, 60        ; sys_exit
    xor rdi, rdi       ; exit status 0
    syscall

; Initialize game state
init_game:
    ; Reset snake
    mov qword [snake_length], 3
    mov byte [snake_x], 7      ; center x
    mov byte [snake_x + 1], 6
    mov byte [snake_x + 2], 5
    mov byte [snake_y], 8      ; center y
    mov byte [snake_y + 1], 8
    mov byte [snake_y + 2], 8
    
    ; Initial direction (right)
    mov qword [snake_dir_x], 1
    mov qword [snake_dir_y], 0
    
    ; Reset score
    mov qword [score], 0
    
    ; Set game running
    mov qword [game_running], 1
    
    ; Place initial food
    call place_food
    ret

; Place food at random location
place_food:
    push rbx
    push rcx
    
place_food_loop:
    ; Generate random x (1 to BOARD_WIDTH-2)
    call random
    mov rdx, 0
    mov rbx, BOARD_WIDTH - 2
    div rbx
    inc rdx
    mov [food_x], rdx
    
    ; Generate random y (1 to BOARD_HEIGHT-2)
    call random
    mov rdx, 0
    mov rbx, BOARD_HEIGHT - 2
    div rbx
    inc rdx
    mov [food_y], rdx
    
    ; Check if food position collides with snake
    mov rcx, [snake_length]
    xor rbx, rbx
    
check_collision_loop:
    cmp rbx, rcx
    jge place_food_done
    
    movzx rax, byte [snake_x + rbx]
    cmp rax, [food_x]
    jne next_segment
    movzx rax, byte [snake_y + rbx]
    cmp rax, [food_y]
    je place_food_loop  ; Collision found, try again
    
next_segment:
    inc rbx
    jmp check_collision_loop
    
place_food_done:
    pop rcx
    pop rbx
    ret

; Simple linear congruential generator for random numbers
random:
    push rdx
    mov rax, [rand_seed]
    mov rdx, 1103515245
    mul rdx
    add rax, 12345
    mov [rand_seed], rax
    pop rdx
    ret

; Setup terminal for raw mode
setup_terminal:
    ; Get current terminal attributes
    mov rax, 16        ; sys_ioctl
    mov rdi, 0         ; stdin
    mov rsi, 0x5401    ; TCGETS
    mov rdx, orig_termios
    syscall
    
    ; Copy to modify
    mov rsi, orig_termios
    sub rsp, 60        ; allocate space for new termios
    mov rdi, rsp
    mov rcx, 60
    rep movsb
    
    ; Modify flags for raw mode
    ; c_lflag &= ~(ICANON | ECHO)
    and dword [rsp + 12], ~(2 | 8)  ; Clear ICANON and ECHO bits
    
    ; Set new terminal attributes
    mov rax, 16        ; sys_ioctl
    mov rdi, 0         ; stdin
    mov rsi, 0x5402    ; TCSETS
    mov rdx, rsp
    syscall
    
    add rsp, 60        ; cleanup stack
    
    ; Hide cursor
    mov rax, 1         ; sys_write
    mov rdi, 1         ; stdout
    mov rsi, hide_cursor
    mov rdx, 6
    syscall
    
    ret

; Restore terminal settings
cleanup_terminal:
    ; Show cursor
    mov rax, 1         ; sys_write
    mov rdi, 1         ; stdout
    mov rsi, show_cursor
    mov rdx, 6
    syscall
    
    ; Restore original terminal attributes
    mov rax, 16        ; sys_ioctl
    mov rdi, 0         ; stdin
    mov rsi, 0x5402    ; TCSETS
    mov rdx, orig_termios
    syscall
    
    ret

; Setup signal handlers
setup_signals:
    ; Setup SIGINT handler (Ctrl+C)
    sub rsp, 152       ; sizeof(struct sigaction) = 152
    mov rdi, rsp
    xor rax, rax
    mov rcx, 152
    rep stosb          ; zero the struct
    
    mov qword [rsp], signal_handler  ; sa_handler
    mov qword [rsp + 8], 0          ; sa_flags
    
    mov rax, 13        ; sys_rt_sigaction
    mov rdi, 2         ; SIGINT
    mov rsi, rsp       ; new action
    xor rdx, rdx       ; old action (NULL)
    mov r10, 8         ; sigsetsize
    syscall
    
    add rsp, 152       ; cleanup stack
    ret

; Signal handler
signal_handler:
    call cleanup_terminal
    mov rax, 60        ; sys_exit
    mov rdi, 1         ; exit status 1
    syscall

; Clear screen
clear_screen_func:
    mov rax, 1         ; sys_write
    mov rdi, 1         ; stdout
    mov rsi, clear_screen
    mov rdx, 7
    syscall
    ret

; Draw the game
draw_game:
    ; Draw title and scores
    call print_string
    mov rsi, title_msg
    call print_string
    
    mov rsi, score_msg
    call print_string
    mov rax, [score]
    call print_number
    
    mov rsi, high_score_msg
    call print_string
    mov rax, [high_score]
    call print_number
    
    ; Draw game board
    mov rbx, 0         ; y coordinate
    
draw_board_loop:
    cmp rbx, BOARD_HEIGHT
    jge draw_board_done
    
    ; Position cursor
    push rbx
    add rbx, 5         ; offset for title/score area
    call set_cursor_pos
    pop rbx
    
    mov rcx, 0         ; x coordinate
    
draw_row_loop:
    cmp rcx, BOARD_WIDTH
    jge draw_row_done
    
    ; Check what to draw at this position
    call get_cell_content
    call print_char
    
    inc rcx
    jmp draw_row_loop
    
draw_row_done:
    inc rbx
    jmp draw_board_loop
    
draw_board_done:
    ; Draw controls
    mov rsi, controls_msg
    call print_string
    ret

; Get content for cell at position (rcx, rbx)
get_cell_content:
    push rdx
    push rsi
    push rdi
    
    ; Check if it's a wall
    cmp rbx, 0
    je draw_wall
    cmp rbx, BOARD_HEIGHT - 1
    je draw_wall
    cmp rcx, 0
    je draw_wall
    cmp rcx, BOARD_WIDTH - 1
    je draw_wall
    
    ; Check if it's food
    cmp rcx, [food_x]
    jne check_snake
    cmp rbx, [food_y]
    jne check_snake
    
    ; Set color and draw food
    mov rsi, yellow_color
    call print_string
    mov al, [FOOD_CHAR]
    jmp get_cell_done
    
check_snake:
    ; Check if it's snake head
    movzx rax, byte [snake_x]
    cmp rcx, rax
    jne check_snake_body
    movzx rax, byte [snake_y]
    cmp rbx, rax
    jne check_snake_body
    
    ; Set color and draw snake head
    mov rsi, green_color
    call print_string
    mov al, [SNAKE_HEAD]
    jmp get_cell_done
    
check_snake_body:
    ; Check snake body segments
    mov rdi, 1         ; start from segment 1 (skip head)
    
check_body_loop:
    cmp rdi, [snake_length]
    jge draw_empty
    
    movzx rax, byte [snake_x + rdi]
    cmp rcx, rax
    jne next_body_segment
    movzx rax, byte [snake_y + rdi]
    cmp rbx, rax
    jne next_body_segment
    
    ; Set color and draw snake body
    mov rsi, green_color
    call print_string
    mov al, [SNAKE_BODY]
    jmp get_cell_done
    
next_body_segment:
    inc rdi
    jmp check_body_loop
    
draw_wall:
    mov rsi, blue_color
    call print_string
    mov al, [WALL_CHAR]
    jmp get_cell_done
    
draw_empty:
    mov rsi, reset_color
    call print_string
    mov al, [EMPTY_CHAR]
    
get_cell_done:
    pop rdi
    pop rsi
    pop rdx
    ret

; Handle input
handle_input:
    call get_input_nonblock
    cmp al, 0
    je handle_input_done
    
    ; Check for quit
    cmp al, 'q'
    je quit_game
    cmp al, 'Q'
    je quit_game
    
    ; Check for direction changes
    cmp al, 'w'
    je move_up
    cmp al, 'W'
    je move_up
    cmp al, 27         ; ESC sequence start
    je check_arrow_keys
    cmp al, 's'
    je move_down
    cmp al, 'S'
    je move_down
    cmp al, 'a'
    je move_left
    cmp al, 'A'
    je move_left
    cmp al, 'd'
    je move_right
    cmp al, 'D'
    je move_right
    jmp handle_input_done
    
check_arrow_keys:
    ; Read next two chars for arrow key sequence
    call get_input
    cmp al, '['
    jne handle_input_done
    call get_input
    cmp al, 'A'        ; Up arrow
    je move_up
    cmp al, 'B'        ; Down arrow
    je move_down
    cmp al, 'C'        ; Right arrow  
    je move_right
    cmp al, 'D'        ; Left arrow
    je move_left
    jmp handle_input_done
    
move_up:
    cmp qword [snake_dir_y], 1  ; Don't reverse into self
    je handle_input_done
    mov qword [snake_dir_x], 0
    mov qword [snake_dir_y], -1
    jmp handle_input_done
    
move_down:
    cmp qword [snake_dir_y], -1 ; Don't reverse into self
    je handle_input_done
    mov qword [snake_dir_x], 0
    mov qword [snake_dir_y], 1
    jmp handle_input_done
    
move_left:
    cmp qword [snake_dir_x], 1  ; Don't reverse into self
    je handle_input_done
    mov qword [snake_dir_x], -1
    mov qword [snake_dir_y], 0
    jmp handle_input_done
    
move_right:
    cmp qword [snake_dir_x], -1 ; Don't reverse into self
    je handle_input_done
    mov qword [snake_dir_x], 1
    mov qword [snake_dir_y], 0
    jmp handle_input_done
    
quit_game:
    mov qword [game_running], 0
    
handle_input_done:
    ret

; Get input (blocking)
get_input:
    mov rax, 0         ; sys_read
    mov rdi, 0         ; stdin
    mov rsi, input_char
    mov rdx, 1
    syscall
    mov al, [input_char]
    ret

; Get input (non-blocking)
get_input_nonblock:
    ; Set stdin to non-blocking
    mov rax, 72        ; sys_fcntl
    mov rdi, 0         ; stdin
    mov rsi, 3         ; F_GETFL
    syscall
    push rax           ; save original flags
    
    or rax, 2048       ; O_NONBLOCK
    mov rdx, rax
    mov rax, 72        ; sys_fcntl
    mov rdi, 0         ; stdin
    mov rsi, 4         ; F_SETFL
    syscall
    
    ; Try to read
    mov rax, 0         ; sys_read
    mov rdi, 0         ; stdin
    mov rsi, input_char
    mov rdx, 1
    syscall
    
    push rax           ; save read result
    
    ; Restore original flags
    pop rdx            ; read result
    pop rax            ; original flags
    push rdx           ; save read result again
    
    mov rdx, rax
    mov rax, 72        ; sys_fcntl
    mov rdi, 0         ; stdin
    mov rsi, 4         ; F_SETFL
    syscall
    
    pop rax            ; restore read result
    cmp rax, 0
    jle no_input
    mov al, [input_char]
    ret
    
no_input:
    xor al, al         ; return 0 if no input
    ret

; Update game state
update_game:
    ; Calculate new head position
    movzx rax, byte [snake_x]
    add rax, [snake_dir_x]
    movzx rbx, byte [snake_y]
    add rbx, [snake_dir_y]
    
    ; Check wall collision
    cmp rax, 0
    jle game_over
    cmp rax, BOARD_WIDTH - 1
    jge game_over
    cmp rbx, 0
    jle game_over
    cmp rbx, BOARD_HEIGHT - 1
    jge game_over
    
    ; Check self collision
    mov rcx, 0
    
check_self_collision:
    cmp rcx, [snake_length]
    jge no_self_collision
    
    movzx rdx, byte [snake_x + rcx]
    cmp rax, rdx
    jne next_self_check
    movzx rdx, byte [snake_y + rcx]
    cmp rbx, rdx
    je game_over
    
next_self_check:
    inc rcx
    jmp check_self_collision
    
no_self_collision:
    ; Check food collision
    mov rdx, 0         ; assume no food eaten
    cmp rax, [food_x]
    jne no_food
    cmp rbx, [food_y]
    jne no_food
    
    ; Food eaten
    mov rdx, 1
    inc qword [score]
    
    ; Check for new high score
    mov rcx, [score]
    cmp rcx, [high_score]
    jle no_new_high_score
    mov [high_score], rcx
    call save_high_score
    
no_new_high_score:
    call place_food
    
no_food:
    ; Move snake
    push rdx           ; save food eaten flag
    
    ; If food wasn't eaten, remove tail
    cmp rdx, 0
    jne skip_tail_removal
    
    dec qword [snake_length]
    
skip_tail_removal:
    ; Shift body segments
    mov rcx, [snake_length]
    
shift_body:
    cmp rcx, 0
    jle shift_done
    
    dec rcx
    mov r8b, [snake_x + rcx]
    mov [snake_x + rcx + 1], r8b
    mov r8b, [snake_y + rcx]
    mov [snake_y + rcx + 1], r8b
    jmp shift_body
    
shift_done:
    ; Place new head
    mov [snake_x], al
    mov [snake_y], bl
    
    pop rdx            ; restore food eaten flag
    cmp rdx, 0
    je update_done
    
    ; Increase length if food was eaten
    inc qword [snake_length]
    
update_done:
    ret
    
game_over:
    mov qword [game_running], 0
    ret

; Draw game over screen
draw_game_over:
    call draw_game
    
    mov rsi, game_over_msg
    call print_string
    
    mov rsi, restart_msg
    call print_string
    
    ret

; Load high score from file
load_high_score:
    push rbx
    push rcx
    push rdx
    
    ; Build full path to high score file
    call build_highscore_path
    
    ; Try to open file
    mov rax, 2         ; sys_open
    mov rdi, highscore_path
    mov rsi, 0         ; O_RDONLY
    syscall
    
    cmp rax, 0
    jl load_default_high_score
    
    ; File opened successfully
    mov rbx, rax       ; save file descriptor
    
    ; Read high score
    mov rax, 0         ; sys_read
    mov rdi, rbx       ; file descriptor
    mov rsi, num_buffer
    mov rdx, 15
    syscall
    
    ; Close file
    push rax           ; save bytes read
    mov rax, 3         ; sys_close
    mov rdi, rbx
    syscall
    pop rax            ; restore bytes read
    
    cmp rax, 0
    jle load_default_high_score
    
    ; Convert string to number
    mov rsi, num_buffer
    call string_to_number
    mov [high_score], rax
    jmp load_high_score_done
    
load_default_high_score:
    mov qword [high_score], 0
    
load_high_score_done:
    pop rdx
    pop rcx
    pop rbx
    ret

; Save high score to file
save_high_score:
    push rbx
    push rcx
    push rdx
    
    ; Build full path
    call build_highscore_path
    
    ; Convert high score to string
    mov rax, [high_score]
    call number_to_string
    
    ; Open file for writing
    mov rax, 2         ; sys_open
    mov rdi, highscore_path
    mov rsi, 0x241     ; O_WRONLY | O_CREAT | O_TRUNC
    mov rdx, 0o644     ; file permissions
    syscall
    
    cmp rax, 0
    jl save_high_score_done
    
    mov rbx, rax       ; save file descriptor
    
    ; Write high score
    mov rax, 1         ; sys_write
    mov rdi, rbx       ; file descriptor
    mov rsi, num_buffer
    mov rdx, rcx       ; string length from number_to_string
    syscall
    
    ; Close file
    mov rax, 3         ; sys_close
    mov rdi, rbx
    syscall
    
save_high_score_done:
    pop rdx
    pop rcx
    pop rbx
    ret

; Build full path to high score file
build_highscore_path:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    
    ; Get HOME environment variable
    mov rax, 79        ; sys_getenv would be ideal, but we'll use a workaround
    ; For simplicity, we'll just use current directory
    mov rdi, highscore_path
    mov rsi, highscore_file
    mov rcx, 16        ; length of ".snake_highscore"
    rep movsb
    mov byte [rdi], 0  ; null terminate
    
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Convert number to string
number_to_string:
    push rbx
    push rdx
    push rsi
    push rdi
    
    mov rdi, num_buffer
    add rdi, 15        ; point to end of buffer
    mov byte [rdi], 0  ; null terminate
    dec rdi
    
    mov rbx, 10        ; divisor
    xor rcx, rcx       ; character count
    
convert_loop:
    xor rdx, rdx
    div rbx
    add dl, '0'        ; convert to ASCII
    mov [rdi], dl
    dec rdi
    inc rcx
    
    cmp rax, 0
    jne convert_loop
    
    ; Move string to beginning of buffer
    inc rdi            ; point to first character
    mov rsi, rdi
    mov rdi, num_buffer
    rep movsb
    
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    ret

; Convert string to number
string_to_number:
    push rbx
    push rcx
    push rdx
    
    xor rax, rax       ; result
    mov rbx, 10        ; multiplier
    
string_to_num_loop:
    movzx rcx, byte [rsi]
    cmp rcx, 0
    je string_to_num_done
    cmp rcx, '0'
    jl string_to_num_done
    cmp rcx, '9'
    jg string_to_num_done
    
    mul rbx
    sub rcx, '0'
    add rax, rcx
    inc rsi
    jmp string_to_num_loop
    
string_to_num_done:
    pop rdx
    pop rcx
    pop rbx
    ret

; Print string
print_string:
    push rax
    push rbx
    push rcx
    push rdx
    
    ; Calculate string length
    mov rdi, rsi
    xor rcx, rcx
    
strlen_loop:
    cmp byte [rdi + rcx], 0
    je strlen_done
    inc rcx
    jmp strlen_loop
    
strlen_done:
    ; Print string
    mov rax, 1         ; sys_write
    mov rdi, 1         ; stdout
    ; rsi already contains string pointer
    mov rdx, rcx       ; length
    syscall
    
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Print single character
print_char:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    
    mov [input_char], al  ; reuse input_char as temp storage
    mov rax, 1         ; sys_write
    mov rdi, 1         ; stdout
    mov rsi, input_char
    mov rdx, 1
    syscall
    
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Print number
print_number:
    push rax
    call number_to_string
    mov rsi, num_buffer
    call print_string
    pop rax
    ret

; Set cursor position
set_cursor_pos:
    push rax
    push rbx
    push rcx
    push rdx
    
    ; Print escape sequence start
    mov rax, 1
    mov rdi, 1
    mov rsi, cursor_pos_start
    mov rdx, 2
    syscall
    
    ; Print row number
    mov rax, rbx
    inc rax            ; 1-based
    call print_number
    
    ; Print separator
    mov rax, 1
    mov rdi, 1
    mov rsi, cursor_pos_sep
    mov rdx, 1
    syscall
    
    ; Print column number  
    mov rax, rcx
    inc rax            ; 1-based
    call print_number
    
    ; Print end
    mov rax, 1
    mov rdi, 1
    mov rsi, cursor_pos_end
    mov rdx, 1
    syscall
    
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Sleep for game timing
sleep_func:
    push rax
    push rbx
    push rcx
    push rdx
    
    sub rsp, 16        ; allocate space for timespec
    mov qword [rsp], 0      ; seconds
    mov qword [rsp + 8], GAME_SPEED * 1000  ; nanoseconds
    
    mov rax, 35        ; sys_nanosleep
    mov rdi, rsp       ; timespec
    xor rsi, rsi       ; remaining (NULL)
    syscall
    
    add rsp, 16        ; cleanup stack
    
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

section .data
    cursor_pos_start    db 27, '['
    cursor_pos_sep      db ';'
    cursor_pos_end      db 'H'
