nasm -f elf64 snake.asm -o snake.o
ld snake.o -o snake
./snake
