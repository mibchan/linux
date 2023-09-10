/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Cache maintenance
 *
 * Copyright (C) 2001 Deep Blue Solutions Ltd.
 * Copyright (C) 2012 ARM Ltd.
 */

#include <linux/errno.h>
#include <linux/linkage.h>
#include <linux/init.h>
#include <asm/assembler.h>
#include <asm/cpufeature.h>
#include <asm/alternative.h>
#include <asm/asm-uaccess.h>

/*
 *	caches_clean_inval_pou_macro(start,end) [fixup]
 *
 *	Ensure that the I and D caches are coherent within specified region.
 *	This is typically used when code has been written to a memory region,
 *	and will be executed.
 *
 *	- start   - virtual start address of region
 *	- end     - virtual end address of region
 *	- fixup   - optional label to branch to on user fault
 */
.macro	caches_clean_inval_pou_macro, fixup
alternative_if ARM64_HAS_CACHE_IDC
	dsb     ishst
	b       .Ldc_skip_\@
alternative_else_nop_endif
	mov     x2, x0
	mov     x3, x1
	dcache_by_line_op cvau, ish, x2, x3, x4, x5, \fixup
.Ldc_skip_\@:
alternative_if ARM64_HAS_CACHE_DIC
	isb
	b	.Lic_skip_\@
alternative_else_nop_endif
	invalidate_icache_by_line x0, x1, x2, x3, \fixup
.Lic_skip_\@:
.endm

/*
 *	caches_clean_inval_pou(start,end)
 *
 *	Ensure that the I and D caches are coherent within specified region.
 *	This is typically used when code has been written to a memory region,
 *	and will be executed.
 *
 *	- start   - virtual start address of region
 *	- end     - virtual end address of region
 */
SYM_FUNC_START(caches_clean_inval_pou)
	caches_clean_inval_pou_macro
	ret
SYM_FUNC_END(caches_clean_inval_pou)
SYM_FUNC_ALIAS(__pi_caches_clean_inval_pou, caches_clean_inval_pou)

/*
 *	caches_clean_inval_user_pou(start,end)
 *
 *	Ensure that the I and D caches are coherent within specified region.
 *	This is typically used when code has been written to a memory region,
 *	and will be executed.
 *
 *	- start   - virtual start address of region
 *	- end     - virtual end address of region
 */
SYM_FUNC_START(caches_clean_inval_user_pou)
	uaccess_ttbr0_enable x2, x3, x4

	caches_clean_inval_pou_macro 2f
	mov	x0, xzr
1:
	uaccess_ttbr0_disable x1, x2
	ret
2:
	mov	x0, #-EFAULT
	b	1b
SYM_FUNC_END(caches_clean_inval_user_pou)

/*
 *	icache_inval_pou(start,end)
 *
 *	Ensure that the I cache is invalid within specified region.
 *
 *	- start   - virtual start address of region
 *	- end     - virtual end address of region
 */
SYM_FUNC_START(icache_inval_pou)
alternative_if ARM64_HAS_CACHE_DIC
	isb
	ret
alternative_else_nop_endif

	invalidate_icache_by_line x0, x1, x2, x3
	ret
SYM_FUNC_END(icache_inval_pou)

/*
 *	dcache_clean_inval_poc(start, end)
 *
 *	Ensure that any D-cache lines for the interval [start, end)
 *	are cleaned and invalidated to the PoC.
 *
 *	- start   - virtual start address of region
 *	- end     - virtual end address of region
 */
SYM_FUNC_START(__pi_dcache_clean_inval_poc)
	dcache_by_line_op civac, sy, x0, x1, x2, x3
	ret
SYM_FUNC_END(__pi_dcache_clean_inval_poc)
SYM_FUNC_ALIAS(dcache_clean_inval_poc, __pi_dcache_clean_inval_poc)

/*
 *	dcache_clean_pou(start, end)
 *
 * 	Ensure that any D-cache lines for the interval [start, end)
 * 	are cleaned to the PoU.
 *
 *	- start   - virtual start address of region
 *	- end     - virtual end address of region
 */
SYM_FUNC_START(dcache_clean_pou)
alternative_if ARM64_HAS_CACHE_IDC
	dsb	ishst
	ret
alternative_else_nop_endif
	dcache_by_line_op cvau, ish, x0, x1, x2, x3
	ret
SYM_FUNC_END(dcache_clean_pou)

/*
 *	dcache_inval_poc(start, end)
 *
 * 	Ensure that any D-cache lines for the interval [start, end)
 * 	are invalidated. Any partial lines at the ends of the interval are
 *	also cleaned to PoC to prevent data loss.
 *
 *	- start   - kernel start address of region
 *	- end     - kernel end address of region
 */

/* 
 * 잘 정리된 블로그: https://ammonia3.tistory.com/10 
 *
 * 이 Function을 수행해야하는 이유 : Invalidation 
 * DTB주소, reserved 0, reserved 0, reserved 0을 저장하기 위해 메모리에 접근하며 (strp)
 * cache-line에 데이터가 써졌을 것이다. (cache를 사용 중이라면)
 * 만약 cache를 사용 중이지 않다면, 어떤 값이 들어있을 지 예상할 수 없다.
 * 따라서 MMU를 켜기 전에 이 주소에 대해 적절히 invalidation을 진행해야 한다.
 *
 * 동작하는 방식 : 
 * 캐시 라인 크기는 64바이트이고, 접근한 메모리 주소 범위는 0x20이다. 
 * 이 0x20 범위가 캐시 라인 한 개에 포함될 수도 있고, 2개에 걸쳐 포함될 수도 있다.
 * 따라서 boot_args의 시작 주소, 끝 주소, 캐시 라인 크기. 이 3개의 변수를 활용해 
 * Invalidation의 범위를 결정한다.
 *
 * 변수들 : 
 * x1 - boot_args의 끝 주소 
 * x2 - 캐시 라인 크기
 * x3 - 캐시 라인에 저장되는 워드 수 -> 캐시 라인 정렬 마스크 비트
 */
SYM_FUNC_START(__pi_dcache_inval_poc)
	/*
	 * 캐시 라인 사이즈를 구한다.
	 * x2 : 64(cache line-size)
	 * x3 : 4 (2^n, cache-line 워드 수) 
	 * 매크로 위치 : arch/arm64/include/asm/assembler.h
	 */
	dcache_line_size x2, x3
	
	/*
	 * x3에는 63이 저장된다. (cache line size - 1)
	 */
	sub	x3, x2, #1

	/*
	 * x1에는 boot_args의 끝 주소가 들어있고, 이 주소의 하위 6비트를 확인한다.
 	 * 이는 2^6 = 64 즉, 64바이트(cache line size)로 정렬되어있는지 확인하기 위함이다.
	 * 연산 결과 값이 0이면 정렬된 것이고, 0이 아니라면 정렬되지 않은 것이다. 
	 * 즉, Z 플래그가 1이라면 정렬된 것, 0이라면 정렬되지 않은 것이다. 
	 * cf) qemu gdb 디버깅 결과, boot_args는 4K 정렬되어 있었고 따라서 boot_args의 끝 주소는 정렬되어있지 않았다. 
	 * 연산 결과 플래그는 N,Z,C,V = {0,0,0,0} 이었다.
	 * cf) 이전에 boto_args의 주소를 adr_l 매크로를 통해서 구했을 때, 4K 정렬된 것을 알 수 있었다.
	 * cf) 만약, boot_args가 4K 정렬되어있지 않은 주소에 있었더라면 cache line size로 정렬됐을 수 있다. 
	 */							
	tst	x1, x3				// end cache line aligned?	

	/*
	 * boot_args의 끝 주소가 정렬되어있지 않았다면 cache line size로 정렬시킨다. 정렬된 주소는 x1에 저장된다.
	 * boot_args의 끝 주소가 정렬되어 있었다면 x1 값에는 변화가 없다.
	 * x1에는 boot_args의 끝 주소가 들어있고, 이 연산 결과 하위 6비트가 클리어된다. (x1 & ~x3) 
  	 * 정렬 여부에 따라 x1은 boot_args 끝 주소를 캐시 라인 크기만큼 내림한 주소 또는 boot_args의 끝 주소를 가리킨다.
	 */
	bic	x1, x1, x3								

	/*
	 * boot_args의 끝 주소가 정렬되지 않은 경우라면(Z 플래그가 0을 의미) 분기하지 않고 그대로 진행한다.  
	 * boot_args의 끝 주소가 정렬된 경우라면(Z 플래그가 1을 의미) 레이블 1로 분기한다. 
 	 * 이 경우에는 boot_args의 끝 주소부터 시작되는 cache line을 invalidate할 필요가 없기 때문이다.
	 */
	b.eq	1f									

	/*
	 * boot_args의 끝 주소가 정렬되어 있지 않은 경우에 해당한다.
	 * cache line size로 정렬한 주소(x19에 들어있는 값)부터 데이터 캐시를 POC까지 Clean & Invalidate를 수행한다. 
	 * 이 범위에는 boot_args가 포함되지 않을 수 있다.
	 */
	dc	civac, x1			// clean & invalidate D / U line											


/* 
 * 레이블 1:
 * boot_args의 시작 주소가 cache line size로 정렬되어있는지 검사하고 Clean & Invalidate 한다.  
 * 시작 주소가 정렬되어있지 않다면 시작 주소가 포함된 캐시 라인을 invalidate 한다.
 * 시작 주소가 정렬되어있다면 레이블 2로 이동한다.
 */
1:	
	/*
	 * boot_args의 시작 주소가 cache line size로 정렬되어있는지 검사한다. 
	 * 연산 결과 값이 0이면 정렬된 것이고, 0이 아니라면 정렬되지 않은 것이다. 
	 * 즉, Z 플래그가 1이라면 정렬된 것, 0이라면 정렬되지 않은 것이다.
	 */
	tst	x0, x3				// start cache line aligned?		
	
	/*
	 * boot_args의 시작 주소가 정렬되어있지 않았다면 cache line size로 정렬시킨다. 정렬된 주소는 x0에 저장된다.
	 * boot_args의 시작 주소가 정렬되어 있었다면 x0 값에는 변화가 없다.
	 * x0에는 boot_args의 시작 주소가 들어있고, 이 연산 결과 하위 6비트가 클리어된다. (x0 & ~x3) 
  	 * 정렬 여부에 따라 x0는 boot_args를 포함하는 정렬된 주소 혹은 boot_args의 시작 주소를 가리킨다.
	 */
	bic	x0, x0, x3
	
	/*
	 * boot_args의 시작 주소가 정렬된 경우에는 레이블 2로 분기한다. 
	 */
	b.eq	2f									

	/*
	 * boot_args의 시작 주소가 정렬되지 않은 경우에 해당한다.
	 * cache line size로 정렬한 주소(x0에 들어있는 값)부터 데이터 캐시를 POC까지 Clean & Invalidate를 수행한다. 
	 * 이 범위에는 boot_args의 시작 주소가 포함된다.
	 */
	dc	civac, x0			// clean & invalidate D / U line		
	
	/*
	 * boot_args의 시작 주소가 정렬되지 않은 경우에는 레이블 3으로 분기한다. (Clean & Invalidate 수행을 완료하였다.)
	 */
	b	3f								


/* 	
* 레이블 2:
* boot_args의 시작 주소가 cache line size로 정렬되어 있는 경우이다. 
*/
2:	
	/*
	 * boot_args의 시작 주소부터 데이터 캐시를 POC까지 Invalidate를 수행한다. 이 범위는 boot_args부터 시작한다.
	 */
	dc	ivac, x0			// invalidate D / U line	


/* 
* 레이블 3:
* boot_args가 포함된 cache line을 Clean & Invalidate 완료한 후의 경우이다. 
* boot_args를 저장하며 갱신된 캐시 라인의 값에 대해 Clean & Invalidate를 보장하기 위함이다. 
*/
3:	
	/*
	 * 다음 캐시 라인의 주소를 x0에 저장한다. (x0은 Clean & Invalidate를 시작한 캐시 라인 주소이고, x2는 캐시 라인 크기이다.)
	 */
	add	x0, x0, x2								

	/*
	 * 다음 캐시 라인의 주소와 boot_args의 끝 주소를 비교한다. 
	 * 다음 캐시 라인의 주소 < boot_args의 끝 주소라면, 다음 캐시라인에 대해 Clean & Invalidate를 해야한다.
	 */
	cmp	x0, x1									

	/*
	 * 다음 캐시 라인의 주소 < boot_args의 끝 주소라면 레이블 2로 이동한다. 
	 * (lo 조건은 플래그의 C 비트를 보고 판단한다. C 비트가 0이라면 조건을 만족한 경우이다.)	
	 */
	b.lo	2b

	/*
	 * 앞에 있는 명령어들이 완전히 수행되는 것을 보장한다.
	 * dsb는 메모리 리오더링과 명령어 리오더링을 함께 방지하는 기능을 제공한다.
	 * 이외에도, 다음과 같은 항목들이 완료될 때 가지 추가 명령어 실행을 멈추고 기다린다.
	 * 1) 명령어 캐시 및 데이터 캐시 조작 		2) 분기 예측 캐시 플러시 		3) 지연된 LOAD/STORE 명령어 처리
	 * 4) DMB 배리어 동작				5) TLB 캐시 조작 완료 
	 */								
	dsb	sy									
	
	/*
	 * 리턴한다.
	 */
	ret										
SYM_FUNC_END(__pi_dcache_inval_poc)
SYM_FUNC_ALIAS(dcache_inval_poc, __pi_dcache_inval_poc)

/*
 *	dcache_clean_poc(start, end)
 *
 * 	Ensure that any D-cache lines for the interval [start, end)
 * 	are cleaned to the PoC.
 *
 *	- start   - virtual start address of region
 *	- end     - virtual end address of region
 */
SYM_FUNC_START(__pi_dcache_clean_poc)
	dcache_by_line_op cvac, sy, x0, x1, x2, x3
	ret
SYM_FUNC_END(__pi_dcache_clean_poc)
SYM_FUNC_ALIAS(dcache_clean_poc, __pi_dcache_clean_poc)

/*
 *	dcache_clean_pop(start, end)
 *
 * 	Ensure that any D-cache lines for the interval [start, end)
 * 	are cleaned to the PoP.
 *
 *	- start   - virtual start address of region
 *	- end     - virtual end address of region
 */
SYM_FUNC_START(__pi_dcache_clean_pop)
	alternative_if_not ARM64_HAS_DCPOP
	b	dcache_clean_poc
	alternative_else_nop_endif
	dcache_by_line_op cvap, sy, x0, x1, x2, x3
	ret
SYM_FUNC_END(__pi_dcache_clean_pop)
SYM_FUNC_ALIAS(dcache_clean_pop, __pi_dcache_clean_pop)
