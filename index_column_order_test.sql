/* ============================================================
 * 복합 인덱스 = 조건 컬럼 순서 검증
 * ------------------------------------------------------------
 * 목적: "= 조건 컬럼끼리는 인덱스 순서를 바꿔도 비용이 같다"
 *       "범위 조건은 맨 뒤로 보내야 한다"
 *       이 두 가지를 100만 건 데이터로 직접 검증한다.
 *
 * 환경: Oracle XE (Docker), 100만 건 더미 데이터
 * ============================================================ */


/* ------------------------------------------------------------
 * 1. 테스트 테이블 생성
 * ------------------------------------------------------------ */
CREATE TABLE trade_history (
    cust_grade   VARCHAR2(1),    -- 고객등급
    cust_no      NUMBER,         -- 고객번호
    trade_date   DATE,           -- 거래일자
    trade_type   VARCHAR2(10),   -- 거래유형
    product_no   NUMBER          -- 상품번호
);


/* ------------------------------------------------------------
 * 2. 더미 데이터 100만 건 생성
 * ------------------------------------------------------------ */
INSERT INTO trade_history
SELECT
    CHR(65 + MOD(LEVEL, 5)),              -- 고객등급: A,B,C,D,E
    TRUNC(DBMS_RANDOM.VALUE(1, 10000)),   -- 고객번호: 1~9999
    DATE '2024-01-01' + MOD(LEVEL, 365),  -- 거래일자: 2024년
    'TYPE' || MOD(LEVEL, 10),             -- 거래유형: TYPE0~9
    TRUNC(DBMS_RANDOM.VALUE(1, 1000))     -- 상품번호: 1~999
FROM DUAL
CONNECT BY LEVEL <= 1000000;

COMMIT;


/* ------------------------------------------------------------
 * 3. 인덱스 3종 생성
 *    A, B : = 조건 컬럼 순서만 다름 (범위는 맨 뒤로 동일)
 *    C    : 범위 조건(trade_date)을 가운데 끼운 잘못된 설계
 * ------------------------------------------------------------ */
CREATE INDEX idx_a ON trade_history(cust_grade, cust_no, trade_date);
CREATE INDEX idx_b ON trade_history(cust_no, cust_grade, trade_date);
CREATE INDEX idx_c ON trade_history(cust_grade, trade_date, cust_no);

-- 옵티마이저용 통계 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, 'TRADE_HISTORY');


/* ------------------------------------------------------------
 * 4. 검증 쿼리
 *    각 쿼리 실행 직후 아래 DISPLAY_CURSOR로 실행계획 확인
 * ------------------------------------------------------------ */

-- [검증 1] IDX_A : (cust_grade, cust_no, trade_date)
SELECT /*+ INDEX(trade_history idx_a) GATHER_PLAN_STATISTICS */ *
FROM   trade_history
WHERE  cust_grade = 'A' AND cust_no = 100 AND trade_date >= DATE '2024-01-01';

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'));


-- [검증 2] IDX_B : (cust_no, cust_grade, trade_date)  ← 앞 두 컬럼 순서만 변경
SELECT /*+ INDEX(trade_history idx_b) GATHER_PLAN_STATISTICS */ *
FROM   trade_history
WHERE  cust_grade = 'A' AND cust_no = 100 AND trade_date >= DATE '2024-01-01';

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'));


-- [검증 3] IDX_C : (cust_grade, trade_date, cust_no)  ← 범위를 가운데 끼운 잘못된 설계
SELECT /*+ INDEX(trade_history idx_c) GATHER_PLAN_STATISTICS */ *
FROM   trade_history
WHERE  cust_grade = 'A' AND cust_no = 100 AND trade_date >= DATE '2024-01-01';

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'));


/* ============================================================
 * [검증 결과 요약]
 *
 *  인덱스   | 스캔 방식          | 인덱스 Buffers | 총 Buffers
 *  ---------|--------------------|----------------|------------
 *  IDX_A    | INDEX RANGE SCAN   |       3        |    27
 *  IDX_B    | INDEX RANGE SCAN   |       3        |    27   ← A와 동일!
 *  IDX_C    | INDEX SKIP SCAN    |      83        |   107   ← 범위 가운데 → 폭증
 *
 *  결론
 *  1) = 조건 컬럼끼리는 순서를 바꿔도 비용 동일 (A == B)
 *  2) 범위 조건을 가운데 두면 뒤 컬럼(cust_no)이 filter로 전락,
 *     옵티마이저가 RANGE SCAN을 포기하고 SKIP SCAN으로 우회 → I/O 폭증
 * ============================================================ */


/* ------------------------------------------------------------
 * 정리 (테스트 후 환경 초기화용)
 * ------------------------------------------------------------ */
-- DROP TABLE trade_history PURGE;