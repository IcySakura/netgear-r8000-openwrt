SECTIONS
{
    . = 0x00212300;
    .text : {
        *(.text*)
    }
    .rodata : ALIGN(4) {
        *(.rodata*)
    }
    .data : ALIGN(4) {
        *(.data*)
    }
    .bss : ALIGN(4) {
        *(.bss*)
        *(COMMON)
    }
    /DISCARD/ : {
        *(.ARM.exidx*)
        *(.ARM.extab*)
        *(.comment)
        *(.note*)
        *(.ARM.attributes)
    }
}
