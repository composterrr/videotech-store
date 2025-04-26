--
-- PostgreSQL database dump
--

-- Dumped from database version 17.4
-- Dumped by pg_dump version 17.4

-- Started on 2025-04-26 12:38:20

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 232 (class 1255 OID 16971)
-- Name: update_client_order_history(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_client_order_history() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    r_id INTEGER;
    c_id INTEGER;
BEGIN
    -- Только если sold стал TRUE
    IF NEW.sold = TRUE AND OLD.sold IS DISTINCT FROM TRUE THEN
        -- Получаем номер чека и клиента по нему
        SELECT receipt_number, client_id
        INTO r_id, c_id
        FROM receipt
        WHERE receipt_number = NEW.receipt_number;

        -- Обновляем order_history, добавляя номер чека, если его там ещё нет
        UPDATE client
        SET order_history = 
            CASE 
                WHEN order_history IS NULL OR order_history = '' THEN r_id::TEXT
                WHEN POSITION(',' || r_id::TEXT || ',' IN ',' || order_history || ',') = 0 THEN order_history || ',' || r_id::TEXT
                ELSE order_history
            END
        WHERE client_id = c_id;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_client_order_history() OWNER TO postgres;

--
-- TOC entry 231 (class 1255 OID 17016)
-- Name: update_final_income_in_report(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_final_income_in_report() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE report
    SET final_income = (
        SELECT COALESCE(SUM(receipt.amount_with_vat), 0)
        FROM receipt
        WHERE receipt.report_number = NEW.report_number
    )
    WHERE report.report_number = NEW.report_number;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_final_income_in_report() OWNER TO postgres;

--
-- TOC entry 245 (class 1255 OID 16975)
-- Name: update_receipt_amount_with_vat(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_receipt_amount_with_vat() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    r_id INTEGER;
    total_cost NUMERIC(10,2);
BEGIN
    -- Проверка: есть ли номер чека
    IF NEW.receipt_number IS NOT NULL THEN
        r_id := NEW.receipt_number;

        SELECT COALESCE(SUM(cost), 0) INTO total_cost
        FROM video_equipment
        WHERE receipt_number = r_id;

        -- Прибавляем 30%
        total_cost := total_cost * 1.30;

        UPDATE receipt
        SET amount_with_vat = total_cost
        WHERE receipt_number = r_id;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_receipt_amount_with_vat() OWNER TO postgres;

--
-- TOC entry 233 (class 1255 OID 16973)
-- Name: update_receipt_product_quantity(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_receipt_product_quantity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    r_id INTEGER;
    qty INTEGER;
BEGIN
    -- Если есть receipt_number, считаем количество
    IF NEW.receipt_number IS NOT NULL THEN
        r_id := NEW.receipt_number;

        SELECT COUNT(*) INTO qty
        FROM video_equipment
        WHERE receipt_number = r_id;

        UPDATE receipt
        SET product_quantity = qty
        WHERE receipt_number = r_id;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_receipt_product_quantity() OWNER TO postgres;

--
-- TOC entry 247 (class 1255 OID 17004)
-- Name: update_sold_tech_quantity(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_sold_tech_quantity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_store_id INTEGER;
BEGIN
    -- Принудительная проверка работы триггера
    RAISE NOTICE 'Триггер сработал! Старое sold: %, Новое sold: %', OLD.sold, NEW.sold;
    
    IF NEW.sold = TRUE AND (OLD.sold IS FALSE OR OLD.sold IS NULL) THEN
        BEGIN
            -- Явная проверка поиска store_id
            SELECT store_number INTO STRICT v_store_id
            FROM supply_category
            WHERE category_number = NEW.category_number;
            
            RAISE NOTICE 'Найден store_id: %', v_store_id;
            
            -- Явный подсчет количества
            PERFORM 1 FROM store WHERE store_number = v_store_id;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Магазин % не найден', v_store_id;
            END IF;
            
            -- Обновление с явной проверкой
            UPDATE store
            SET sold_tech_quantity = (
                SELECT COUNT(*) 
                FROM video_equipment ve
                JOIN supply_category sc ON ve.category_number = sc.category_number
                WHERE ve.sold = TRUE AND sc.store_number = v_store_id
            )
            WHERE store_number = v_store_id
            RETURNING sold_tech_quantity INTO v_store_id;
            
            RAISE NOTICE 'Обновлено sold_tech_quantity: %', v_store_id;
            
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'Ошибка в триггере: %', SQLERRM;
        END;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_sold_tech_quantity() OWNER TO postgres;

--
-- TOC entry 230 (class 1255 OID 17014)
-- Name: update_sold_tech_quantity_in_report(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_sold_tech_quantity_in_report() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Обновляем поле sold_tech_quantity в таблице report
    UPDATE report
    SET sold_tech_quantity = (
        SELECT COUNT(*)
        FROM receipt
        WHERE receipt.report_number = NEW.report_number
    )
    WHERE report.report_number = NEW.report_number;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_sold_tech_quantity_in_report() OWNER TO postgres;

--
-- TOC entry 229 (class 1255 OID 16965)
-- Name: update_status_to_sold(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_status_to_sold() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Проверяем, было ли установлено значение receipt_number
    IF NEW.receipt_number IS NOT NULL THEN
        NEW.sold := 'true';
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_status_to_sold() OWNER TO postgres;

--
-- TOC entry 246 (class 1255 OID 16969)
-- Name: update_store_sold_quantity(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_store_sold_quantity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    store_id INTEGER;
BEGIN
    IF NEW.sold = TRUE AND (OLD.sold IS FALSE OR OLD.sold IS NULL) THEN
        -- Получаем store_number по article через category_number
        SELECT store_number INTO store_id
        FROM supply_category
        WHERE category_number = NEW.category_number;

        -- Обновляем счетчик в store
        UPDATE store
        SET sold_tech_quantity = (
            SELECT COUNT(*) 
            FROM video_equipment ve
            JOIN supply_category sc ON ve.category_number = sc.category_number
            WHERE ve.sold = TRUE AND sc.store_number = store_id
        )
        WHERE store_number = store_id;
    END IF;
    RETURN NEW;
END;$$;


ALTER FUNCTION public.update_store_sold_quantity() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 225 (class 1259 OID 16843)
-- Name: accounting; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.accounting (
    department_number integer NOT NULL,
    chief_accountant_id integer,
    phone_num character varying(100),
    email character varying(100)
);


ALTER TABLE public.accounting OWNER TO postgres;

--
-- TOC entry 223 (class 1259 OID 16826)
-- Name: client; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.client (
    client_id integer NOT NULL,
    order_history text
);


ALTER TABLE public.client OWNER TO postgres;

--
-- TOC entry 227 (class 1259 OID 16918)
-- Name: client_contacts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.client_contacts (
    client_id integer NOT NULL,
    phone character varying(20),
    email character varying(100),
    contact_id integer NOT NULL
);


ALTER TABLE public.client_contacts OWNER TO postgres;

--
-- TOC entry 228 (class 1259 OID 16986)
-- Name: client_contacts_contact_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.client_contacts_contact_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.client_contacts_contact_id_seq OWNER TO postgres;

--
-- TOC entry 4895 (class 0 OID 0)
-- Dependencies: 228
-- Name: client_contacts_contact_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.client_contacts_contact_id_seq OWNED BY public.client_contacts.contact_id;


--
-- TOC entry 218 (class 1259 OID 16799)
-- Name: contract; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.contract (
    contract_number integer NOT NULL,
    supplier_legal_address character varying(255),
    validity_period date,
    contract_text text,
    employee_id integer,
    active integer
);


ALTER TABLE public.contract OWNER TO postgres;

--
-- TOC entry 217 (class 1259 OID 16792)
-- Name: employee; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.employee (
    id integer NOT NULL,
    "position" character varying(255),
    phone character varying(255),
    email character varying(255)
);


ALTER TABLE public.employee OWNER TO postgres;

--
-- TOC entry 224 (class 1259 OID 16838)
-- Name: receipt; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.receipt (
    receipt_number integer NOT NULL,
    amount_with_vat numeric(10,2),
    payment_date date,
    issue_date date,
    status character varying(50),
    client_id integer,
    product_quantity integer,
    report_number integer
);


ALTER TABLE public.receipt OWNER TO postgres;

--
-- TOC entry 226 (class 1259 OID 16848)
-- Name: report; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.report (
    report_number integer NOT NULL,
    sold_tech_quantity integer,
    final_income numeric(10,2),
    government_agency_code character varying(50),
    employee_id integer
);


ALTER TABLE public.report OWNER TO postgres;

--
-- TOC entry 221 (class 1259 OID 16816)
-- Name: store; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.store (
    store_number integer NOT NULL,
    sold_tech_quantity integer,
    manager_id integer
);


ALTER TABLE public.store OWNER TO postgres;

--
-- TOC entry 219 (class 1259 OID 16806)
-- Name: supply; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.supply (
    batch_code integer NOT NULL,
    category_count integer,
    payment_status character varying(50),
    shipping_status character varying(50),
    product_received_date date,
    total_cost numeric(10,2),
    contract_number integer
);


ALTER TABLE public.supply OWNER TO postgres;

--
-- TOC entry 220 (class 1259 OID 16811)
-- Name: supply_category; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.supply_category (
    category_number integer NOT NULL,
    product_quantity integer,
    product_cost numeric(10,2),
    store_number integer,
    batch_code integer
);


ALTER TABLE public.supply_category OWNER TO postgres;

--
-- TOC entry 222 (class 1259 OID 16821)
-- Name: video_equipment; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.video_equipment (
    article integer NOT NULL,
    name character varying(255),
    cost numeric(10,2),
    weight numeric(10,2),
    category_number integer,
    sold boolean DEFAULT false,
    receipt_number integer,
    manufacturer character varying(255)
);


ALTER TABLE public.video_equipment OWNER TO postgres;

--
-- TOC entry 4690 (class 2604 OID 16987)
-- Name: client_contacts contact_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_contacts ALTER COLUMN contact_id SET DEFAULT nextval('public.client_contacts_contact_id_seq'::regclass);


--
-- TOC entry 4886 (class 0 OID 16843)
-- Dependencies: 225
-- Data for Name: accounting; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.accounting (department_number, chief_accountant_id, phone_num, email) FROM stdin;
1	3	555-001-1234	accounting@company.com
\.


--
-- TOC entry 4884 (class 0 OID 16826)
-- Dependencies: 223
-- Data for Name: client; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.client (client_id, order_history) FROM stdin;
1	
2	
3	
4	
5	
6	
7	
\.


--
-- TOC entry 4888 (class 0 OID 16918)
-- Dependencies: 227
-- Data for Name: client_contacts; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.client_contacts (client_id, phone, email, contact_id) FROM stdin;
1	123-456-7890	client1@example.com	1
2	234-567-8901	client2@example.com	2
3	345-678-9012	client3@example.com	3
4	456-789-0123	client4@example.com	4
5	567-890-1234	client5@example.com	5
6	678-901-2345	client6@example.com	6
7	789-012-3456	client7@example.com	7
\.


--
-- TOC entry 4879 (class 0 OID 16799)
-- Dependencies: 218
-- Data for Name: contract; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.contract (contract_number, supplier_legal_address, validity_period, contract_text, employee_id, active) FROM stdin;
1	LLC "TechNova Supplies"	2023-02-15	The supplier agrees to deliver technical equipment in accordance with the agreed schedule and specifications.	2	0
2	JSC "Digital Horizons"	2015-05-26	This contract ensures the supply of certified video equipment with full compliance to current regulatory standards.	4	1
\.


--
-- TOC entry 4878 (class 0 OID 16792)
-- Dependencies: 217
-- Data for Name: employee; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.employee (id, "position", phone, email) FROM stdin;
1	Manager	123-456-7890	manager1@example.com
2	Sales	123-456-7891	sales1@example.com
3	Technician	123-456-7892	technician1@example.com
4	Manager	123-456-7893	manager2@example.com
5	Sales	123-456-7894	sales2@example.com
6	Technician	123-456-7895	technician2@example.com
7	Manager	123-456-7896	manager3@example.com
8	Sales	123-456-7897	sales3@example.com
9	Technician	123-456-7898	technician3@example.com
10	Manager	123-456-7899	manager4@example.com
11	Sales	123-456-7800	sales4@example.com
12	Technician	123-456-7801	technician4@example.com
13	Manager	123-456-7802	manager5@example.com
14	Sales	123-456-7803	sales5@example.com
15	Technician	123-456-7804	technician5@example.com
\.


--
-- TOC entry 4885 (class 0 OID 16838)
-- Dependencies: 224
-- Data for Name: receipt; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.receipt (receipt_number, amount_with_vat, payment_date, issue_date, status, client_id, product_quantity, report_number) FROM stdin;
1	5850.00	2025-04-25	2025-04-25	Pending	1	3	1
2	7670.00	2025-04-25	2025-04-25	Pending	2	3	1
3	5590.00	2025-04-25	2025-04-25	Pending	3	3	1
6	6760.00	2025-04-25	2025-04-25	Pending	6	3	2
4	6760.00	2025-04-25	2025-04-25	Pending	4	3	2
5	6110.00	2025-04-25	2025-04-25	Pending	5	3	2
7	6760.00	2025-04-25	2025-04-25	Pending	7	3	2
\.


--
-- TOC entry 4887 (class 0 OID 16848)
-- Dependencies: 226
-- Data for Name: report; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.report (report_number, sold_tech_quantity, final_income, government_agency_code, employee_id) FROM stdin;
1	3	19110.00	Федеральная налоговая служба	3
2	4	26390.00	Федеральная налоговая служба	7
\.


--
-- TOC entry 4882 (class 0 OID 16816)
-- Dependencies: 221
-- Data for Name: store; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.store (store_number, sold_tech_quantity, manager_id) FROM stdin;
1	0	1
3	0	7
2	6	4
\.


--
-- TOC entry 4880 (class 0 OID 16806)
-- Dependencies: 219
-- Data for Name: supply; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.supply (batch_code, category_count, payment_status, shipping_status, product_received_date, total_cost, contract_number) FROM stdin;
2001	3	Paid	Delivered	2025-01-15	15000.00	1
2002	3	Pending	Shipped	2025-02-15	20000.00	2
2003	3	Paid	Delivered	2025-03-15	18000.00	1
\.


--
-- TOC entry 4881 (class 0 OID 16811)
-- Dependencies: 220
-- Data for Name: supply_category; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.supply_category (category_number, product_quantity, product_cost, store_number, batch_code) FROM stdin;
1	4	5000.00	1	2001
2	4	7000.00	2	2002
3	4	6000.00	3	2003
4	3	8000.00	1	2003
5	3	7500.00	2	2002
6	3	6500.00	3	2001
7	4	7200.00	1	2001
\.


--
-- TOC entry 4883 (class 0 OID 16821)
-- Dependencies: 222
-- Data for Name: video_equipment; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.video_equipment (article, name, cost, weight, category_number, sold, receipt_number, manufacturer) FROM stdin;
1006	Sony FX3	2200.00	2.20	2	t	2	Sony
1007	Panasonic HC-X2000	1300.00	1.60	2	t	2	Panasonic
1008	Canon XA11	1200.00	1.80	2	t	2	Canon
1009	Sony PXW-Z90	1800.00	2.10	3	t	3	Sony
1010	Panasonic AG-CX10	1500.00	1.70	3	t	3	Panasonic
1011	Blackmagic Pocket 6K	2000.00	2.50	3	t	3	Blackmagic
1012	Canon XF405	1700.00	1.90	3	t	3	Canon
1013	Sony FX3	2200.00	2.20	4	t	4	Sony
1014	Panasonic HC-X2000	1300.00	1.60	4	t	4	Panasonic
1015	Canon XA11	1200.00	1.80	4	t	4	Canon
1016	Sony PXW-Z90	1800.00	2.10	5	t	5	Sony
1017	Panasonic AG-CX10	1500.00	1.70	5	t	5	Panasonic
1018	Blackmagic Pocket 6K	2000.00	2.50	5	t	5	Blackmagic
1019	Canon XF405	1700.00	1.90	6	t	6	Canon
1020	Sony FX3	2200.00	2.20	6	t	6	Sony
1021	Panasonic HC-X2000	1300.00	1.60	6	t	6	Panasonic
1022	Canon XA11	1200.00	1.80	7	t	7	Canon
1023	Sony PXW-Z90	1800.00	2.10	7	t	7	Sony
1004	Blackmagic Pocket 6K	2000.00	2.50	1	t	1	Blackmagic
1002	Sony PXW-Z90	1800.00	2.10	1	t	1	Sony
1003	Panasonic AG-CX10	1500.00	1.70	1	t	1	Panasonic
1001	Canon XA11	1200.00	1.80	1	t	1	Canon
1005	Canon XF405	1700.00	1.90	2	t	6	Canon
1024	Panasonic AG-CX10	1500.00	1.70	7	t	7	Panasonic
1025	Blackmagic Pocket 6K	2000.00	2.50	7	t	7	Blackmagic
\.


--
-- TOC entry 4896 (class 0 OID 0)
-- Dependencies: 228
-- Name: client_contacts_contact_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.client_contacts_contact_id_seq', 7, true);


--
-- TOC entry 4708 (class 2606 OID 16847)
-- Name: accounting accounting_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounting
    ADD CONSTRAINT accounting_pkey PRIMARY KEY (department_number);


--
-- TOC entry 4712 (class 2606 OID 16989)
-- Name: client_contacts client_contacts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_contacts
    ADD CONSTRAINT client_contacts_pkey PRIMARY KEY (contact_id);


--
-- TOC entry 4704 (class 2606 OID 16832)
-- Name: client client_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client
    ADD CONSTRAINT client_pkey PRIMARY KEY (client_id);


--
-- TOC entry 4694 (class 2606 OID 16805)
-- Name: contract contract_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contract
    ADD CONSTRAINT contract_pkey PRIMARY KEY (contract_number);


--
-- TOC entry 4692 (class 2606 OID 16798)
-- Name: employee employee_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.employee
    ADD CONSTRAINT employee_pkey PRIMARY KEY (id);


--
-- TOC entry 4706 (class 2606 OID 16842)
-- Name: receipt receipt_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.receipt
    ADD CONSTRAINT receipt_pkey PRIMARY KEY (receipt_number);


--
-- TOC entry 4710 (class 2606 OID 16852)
-- Name: report report_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.report
    ADD CONSTRAINT report_pkey PRIMARY KEY (report_number);


--
-- TOC entry 4700 (class 2606 OID 16820)
-- Name: store store_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.store
    ADD CONSTRAINT store_pkey PRIMARY KEY (store_number);


--
-- TOC entry 4698 (class 2606 OID 16815)
-- Name: supply_category supply_category_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.supply_category
    ADD CONSTRAINT supply_category_pkey PRIMARY KEY (category_number);


--
-- TOC entry 4696 (class 2606 OID 16810)
-- Name: supply supply_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.supply
    ADD CONSTRAINT supply_pkey PRIMARY KEY (batch_code);


--
-- TOC entry 4702 (class 2606 OID 16825)
-- Name: video_equipment video_equipment_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.video_equipment
    ADD CONSTRAINT video_equipment_pkey PRIMARY KEY (article);


--
-- TOC entry 4725 (class 2620 OID 17008)
-- Name: video_equipment trg_update_client_order_history; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_client_order_history BEFORE UPDATE OF receipt_number ON public.video_equipment FOR EACH ROW EXECUTE FUNCTION public.update_client_order_history();


--
-- TOC entry 4731 (class 2620 OID 17017)
-- Name: receipt trg_update_final_income_in_report; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_final_income_in_report AFTER UPDATE OF report_number ON public.receipt FOR EACH ROW EXECUTE FUNCTION public.update_final_income_in_report();


--
-- TOC entry 4726 (class 2620 OID 17009)
-- Name: video_equipment trg_update_receipt_amount_with_vat; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_receipt_amount_with_vat BEFORE UPDATE OF receipt_number ON public.video_equipment FOR EACH ROW EXECUTE FUNCTION public.update_receipt_amount_with_vat();


--
-- TOC entry 4727 (class 2620 OID 17010)
-- Name: video_equipment trg_update_receipt_product_quantity; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_receipt_product_quantity BEFORE UPDATE OF receipt_number ON public.video_equipment FOR EACH ROW EXECUTE FUNCTION public.update_receipt_product_quantity();


--
-- TOC entry 4728 (class 2620 OID 17011)
-- Name: video_equipment trg_update_sold_tech_quantity; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_sold_tech_quantity BEFORE UPDATE OF receipt_number ON public.video_equipment FOR EACH ROW EXECUTE FUNCTION public.update_sold_tech_quantity();


--
-- TOC entry 4732 (class 2620 OID 17015)
-- Name: receipt trg_update_sold_tech_quantity_in_report; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_sold_tech_quantity_in_report AFTER UPDATE OF report_number ON public.receipt FOR EACH ROW EXECUTE FUNCTION public.update_sold_tech_quantity_in_report();


--
-- TOC entry 4729 (class 2620 OID 17012)
-- Name: video_equipment trg_update_status_to_sold; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_status_to_sold BEFORE UPDATE OF receipt_number ON public.video_equipment FOR EACH ROW EXECUTE FUNCTION public.update_status_to_sold();


--
-- TOC entry 4730 (class 2620 OID 17013)
-- Name: video_equipment trg_update_store_sold_quantity; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_store_sold_quantity BEFORE UPDATE OF receipt_number ON public.video_equipment FOR EACH ROW EXECUTE FUNCTION public.update_store_sold_quantity();


--
-- TOC entry 4722 (class 2606 OID 16888)
-- Name: accounting accounting_chief_accountant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounting
    ADD CONSTRAINT accounting_chief_accountant_id_fkey FOREIGN KEY (chief_accountant_id) REFERENCES public.employee(id);


--
-- TOC entry 4724 (class 2606 OID 16924)
-- Name: client_contacts client_contacts_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_contacts
    ADD CONSTRAINT client_contacts_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.client(client_id);


--
-- TOC entry 4713 (class 2606 OID 16853)
-- Name: contract contract_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contract
    ADD CONSTRAINT contract_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employee(id);


--
-- TOC entry 4720 (class 2606 OID 16942)
-- Name: receipt fk_receipt_report; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.receipt
    ADD CONSTRAINT fk_receipt_report FOREIGN KEY (report_number) REFERENCES public.report(report_number);


--
-- TOC entry 4715 (class 2606 OID 16954)
-- Name: supply_category fk_store_number; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.supply_category
    ADD CONSTRAINT fk_store_number FOREIGN KEY (store_number) REFERENCES public.store(store_number);


--
-- TOC entry 4721 (class 2606 OID 16883)
-- Name: receipt receipt_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.receipt
    ADD CONSTRAINT receipt_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.client(client_id);


--
-- TOC entry 4723 (class 2606 OID 16893)
-- Name: report report_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.report
    ADD CONSTRAINT report_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employee(id);


--
-- TOC entry 4717 (class 2606 OID 16868)
-- Name: store store_manager_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.store
    ADD CONSTRAINT store_manager_id_fkey FOREIGN KEY (manager_id) REFERENCES public.employee(id);


--
-- TOC entry 4716 (class 2606 OID 16863)
-- Name: supply_category supply_category_batch_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.supply_category
    ADD CONSTRAINT supply_category_batch_code_fkey FOREIGN KEY (batch_code) REFERENCES public.supply(batch_code);


--
-- TOC entry 4714 (class 2606 OID 16858)
-- Name: supply supply_contract_number_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.supply
    ADD CONSTRAINT supply_contract_number_fkey FOREIGN KEY (contract_number) REFERENCES public.contract(contract_number);


--
-- TOC entry 4718 (class 2606 OID 16873)
-- Name: video_equipment video_equipment_category_number_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.video_equipment
    ADD CONSTRAINT video_equipment_category_number_fkey FOREIGN KEY (category_number) REFERENCES public.supply_category(category_number);


--
-- TOC entry 4719 (class 2606 OID 16931)
-- Name: video_equipment video_equipment_receipt_number_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.video_equipment
    ADD CONSTRAINT video_equipment_receipt_number_fkey FOREIGN KEY (receipt_number) REFERENCES public.receipt(receipt_number);


-- Completed on 2025-04-26 12:38:21

--
-- PostgreSQL database dump complete
--

