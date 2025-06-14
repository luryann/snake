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
    title_string    db 'S N A K E   G A M E', 0
    score_prefix    db 'Score: ', 0
    high_score_prefix db 'High Score: ', 0
    game_over_text  db 'G A M E   O V E R !', 0
    restart_text    db 'Press R to restart, Q to quit', 0
    controls_text   db 'Controls: WASD or Arrow Keys, Q to quit', 0
    
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
    
    ; Terminal dimensions
    term_width      resq 1
    term_height     resq 1
    game_offset_x   resq 1
    game_offset_y   resq 1
    
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
    
    ; Get terminal size and calculate centering
    call get_terminal_size
    call calculate_game_position
    
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
    ; Check if we have enough space to draw everything
    mov rax, [term_height]
    cmp rax, 10         ; minimum height needed
    jl draw_minimal
    
    mov rax, [term_width]
    cmp rax, BOARD_WIDTH
    jl draw_minimal
    
    ; Normal drawing with full interface
    jmp draw_full_interface
    
draw_minimal:
    ; Calculate minimal centering
    push r14
    push r15

    ; Horizontal centering: (term_width - BOARD_WIDTH) / 2
    mov r14, [term_width]
    sub r14, BOARD_WIDTH
    shr r14, 1
    cmp r14, 0
    jge minimal_x_ok
    mov r14, 0
minimal_x_ok:
    ; Vertical centering: (term_height - BOARD_HEIGHT) / 2
    mov r15, [term_height]
    sub r15, BOARD_HEIGHT
    shr r15, 1
    cmp r15, 0
    jge minimal_y_ok
    mov r15, 0
minimal_y_ok:

    mov r12, 0         ; y coordinate

draw_minimal_loop:
    cmp r12, BOARD_HEIGHT
    jge draw_minimal_done
    
    ; Set cursor position with centering
    mov rbx, r15
    add rbx, r12       ; centered Y position
    mov rcx, r14
    add rcx, r13       ; centered X position
    call set_cursor_pos
    
    mov r13, 0         ; x coordinate
    
draw_minimal_row:
    cmp r13, BOARD_WIDTH
    jge draw_minimal_row_done
    
    mov rcx, r13
    mov rbx, r12
    call get_cell_content
    call print_char
    
    inc r13
    jmp draw_minimal_row
    
draw_minimal_row_done:
    inc r12
    jmp draw_minimal_loop
    
draw_minimal_done:
    pop r15
    pop r14
    ret
    
draw_full_interface:
    ; Draw title (centered above game board)
    mov rbx, [game_offset_y]
    mov rcx, [game_offset_x]
    
    ; Center title within game width
    mov rax, BOARD_WIDTH
    sub rax, 19        ; length of "S N A K E   G A M E"
    shr rax, 1
    add rcx, rax
    call set_cursor_pos
    
    mov rsi, cyan_color
    call print_string
    mov rsi, title_string
    call print_string
    mov rsi, reset_color
    call print_string
    
    ; Draw score and high score on same line
    mov rbx, [game_offset_y]
    inc rbx            ; next line
    mov rcx, [game_offset_x]
    call set_cursor_pos
    
    mov rsi, score_prefix
    call print_string
    mov rax, [score]
    call print_number
    
    ; Calculate position for high score (right side of game area)
    mov rcx, [game_offset_x]
    add rcx, BOARD_WIDTH
    sub rcx, 15        ; approximate width of "High Score: XXX"
    call set_cursor_pos
    
    mov rsi, high_score_prefix
    call print_string
    mov rax, [high_score]
    call print_number
    
    ; Add blank line before game board
    inc rbx
    
    ; Draw game board
    mov r12, 0         ; y coordinate
    
draw_board_loop:
    cmp r12, BOARD_HEIGHT
    jge draw_board_done
    
    ; Position cursor with calculated offsets
    mov rbx, [game_offset_y]
    add rbx, r12
    add rbx, 2         ; account for title and score lines
    mov rcx, [game_offset_x]
    call set_cursor_pos
    
    mov r13, 0         ; x coordinate
    
draw_row_loop:
    cmp r13, BOARD_WIDTH
    jge draw_row_done
    
    ; Get cell content and draw
    mov rcx, r13       ; x position
    mov rbx, r12       ; y position
    call get_cell_content
    call print_char
    
    inc r13
    jmp draw_row_loop
    
draw_row_done:
    inc r12
    jmp draw_board_loop
    
draw_board_done:
    ; Draw controls (only if there's space)
    mov rax, [game_offset_y]
    add rax, BOARD_HEIGHT
    add rax, 2         ; only need 1 row below board for controls
    cmp rax, [term_height]
    jge skip_controls  ; skip if no room
    
    mov rbx, [game_offset_y]
    add rbx, BOARD_HEIGHT
    add rbx, 2         ; spacing below game
    mov rcx, [game_offset_x]
    call set_cursor_pos
    mov rsi, controls_text
    
skip_controls:
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

; Get terminal size using TIOCGWINSZ ioctl
get_terminal_size:
    push rbx
    push rcx
    push rdx
    
    ; Allocate space for winsize struct (4 shorts = 8 bytes)
    sub rsp, 8
    
    ; Get window size
    mov rax, 16        ; sys_ioctl
    mov rdi, 1         ; stdout
    mov rsi, 0x5413    ; TIOCGWINSZ
    mov rdx, rsp       ; winsize struct
    syscall
    
    ; Extract dimensions
    movzx rax, word [rsp]      ; ws_row (height)
    mov [term_height], rax
    movzx rax, word [rsp + 2]  ; ws_col (width)
    mov [term_width], rax
    
    add rsp, 8         ; cleanup stack
    
    ; Set defaults if ioctl failed
    cmp qword [term_height], 0
    jne size_ok
    mov qword [term_height], 24
    mov qword [term_width], 80
    
size_ok:
    pop rdx
    pop rcx
    pop rbx
    ret

; Calculate centered position for game
calculate_game_position:
    ; Total required width: BOARD_WIDTH
    mov rax, BOARD_WIDTH
    
    ; Check if terminal is wide enough
    cmp rax, [term_width]
    jg too_narrow
    
    ; Calculate horizontal offset: (term_width - BOARD_WIDTH) / 2
    mov rax, [term_width]
    sub rax, BOARD_WIDTH
    shr rax, 1         ; divide by 2
    mov [game_offset_x], rax
    jmp check_height
    
too_narrow:
    ; Terminal too narrow, use minimal offset
    mov qword [game_offset_x], 1
    
check_height:
    ; Total required height: BOARD_HEIGHT + 5 (title+score+controls+spacing)
    mov rax, BOARD_HEIGHT
    add rax, 5
    
    ; Check if terminal is tall enough
    cmp rax, [term_height]
    jg too_short
    
    ; Calculate vertical offset: (term_height - total_height) / 2
    mov rax, [term_height]
    sub rax, BOARD_HEIGHT
    sub rax, 5
    shr rax, 1         ; divide by 2
    mov [game_offset_y], rax
    jmp ensure_minimums
    
too_short:
    ; Terminal too short, use minimal offset
    mov qword [game_offset_y], 1
    
ensure_minimums:
    ; Ensure minimum offsets (never negative)
    cmp qword [game_offset_x], 0
    jge x_offset_ok
    mov qword [game_offset_x], 0
    
x_offset_ok:
    cmp qword [game_offset_y], 0
    jge y_offset_ok
    mov qword [game_offset_y], 0
    
y_offset_ok:
    ; Ensure we don't go off screen
    ; Max X offset = term_width - BOARD_WIDTH
    mov rax, [term_width]
    sub rax, BOARD_WIDTH
    cmp [game_offset_x], rax
    jle x_bounds_ok
    mov [game_offset_x], rax
    
x_bounds_ok:
    ; Max Y offset = term_height - BOARD_HEIGHT - 5
    mov rax, [term_height]
    sub rax, BOARD_HEIGHT
    sub rax, 5
    cmp [game_offset_y], rax
    jle y_bounds_ok
    mov [game_offset_y], rax
    
y_bounds_ok:
    ; Final safety check - ensure offsets are not negative
    cmp qword [game_offset_x], 0
    jge final_x_ok
    mov qword [game_offset_x], 0
    
final_x_ok:
    cmp qword [game_offset_y], 0
    jge final_y_ok
    mov qword [game_offset_y], 0
    
final_y_ok:
    ret
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
    
    ; Draw game over message (centered)
    mov rbx, [game_offset_y]
    add rbx, 8                 ; middle of game area
    mov rcx, [game_offset_x]
    add rcx, 2                 ; slight indent
    call set_cursor_pos
    
    mov rsi, red_color
    call print_string
    mov rsi, game_over_text
    call print_string
    mov rsi, reset_color
    call print_string
    
    ; Draw restart message
    add rbx, 2                 ; two lines down
    mov rcx, [game_offset_x]
    call set_cursor_pos
    mov rsi, restart_text
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

; Set cursor position (rbx = row, rcx = col, both 0-based)
set_cursor_pos:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    
    ; Build cursor position string manually
    ; ESC[row;colH format
    
    ; Print ESC[
    mov rax, 1
    mov rdi, 1
    mov rsi, esc_bracket
    mov rdx, 2
    syscall
    
    ; Print row number (1-based)
    mov rax, rbx
    inc rax
    call print_number
    
    ; Print semicolon
    mov rax, 1
    mov rdi, 1
    mov rsi, semicolon
    mov rdx, 1
    syscall
    
    ; Print column number (1-based)
    mov rax, rcx
    inc rax
    call print_number
    
    ; Print H
    mov rax, 1
    mov rdi, 1
    mov rsi, cursor_h
    mov rdx, 1
    syscall
    
    pop rdi
    pop rsi
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
    esc_bracket         db 27, '['
    semicolon           db ';'
    cursor_h            db 'H'
