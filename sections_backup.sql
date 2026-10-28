--
-- PostgreSQL database dump
--

\restrict gvT28qkBP8aCmhD0xLGzyI9PrOD2WVLuVsoebVeyId6aR2UbKWmTYe3YSKF1rro

-- Dumped from database version 17.11 (Debian 17.11-1.pgdg13+2)
-- Dumped by pg_dump version 17.11 (Debian 17.11-1.pgdg13+2)

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
-- Data for Name: sections; Type: TABLE DATA; Schema: public; Owner: checkmate
--

INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (1, 11, 'ABM11-A', 1, '2026-2027', 1, '2026-10-19 07:40:11.862305+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (2, 10, 'STEM11-A', 1, '2026-2027', 1, '2026-10-19 07:40:27.175136+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (3, 9, 'BSIT11A', 1, '2026-2027', 1, '2026-10-19 07:40:35.996979+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (4, 1, 'BACOMM21A', 2, '2026-2027', 1, '2026-10-19 07:40:41.139609+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (5, 9, 'BSIT11B', 1, '2026-2027', 1, '2026-10-19 07:41:08.133882+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (6, 9, 'BSIT11C', 1, '2026-2027', 1, '2026-10-19 07:41:13.469869+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (7, 9, 'BSIT21A', 2, '2026-2027', 1, '2026-10-19 07:41:25.461658+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (8, 9, 'BSIT21B', 2, '2026-2027', 1, '2026-10-19 07:41:37.671396+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (9, 1, 'BACOMM11A', 1, '2026-2027', 1, '2026-10-20 12:35:52.174133+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (10, 1, 'BACOMM11B', 1, '2026-2027', 1, '2026-10-20 12:35:52.174133+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (11, 1, 'BACOMM11C', 1, '2026-2027', 1, '2026-10-20 12:35:52.174133+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (12, 1, 'BACOMM11D', 1, '2026-2027', 1, '2026-10-20 12:35:52.174133+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (13, 1, 'BACOMM11E', 1, '2026-2027', 1, '2026-10-20 12:35:52.174133+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (14, 9, 'BSIT41A', 4, '2026-2027', 1, '2026-10-20 12:38:26.123947+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (15, 9, 'BSIT41B', 4, '2026-2027', 1, '2026-10-20 12:38:26.123947+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (16, 9, 'BSIT41C', 4, '2026-2027', 1, '2026-10-20 12:38:26.123947+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (17, 9, 'BSIT41D', 4, '2026-2027', 1, '2026-10-20 12:38:26.123947+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (18, 9, 'BSIT31A', 3, '2026-2027', 1, '2026-10-25 15:27:40.516572+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (19, 9, 'BSIT31B', 3, '2026-2027', 1, '2026-10-25 15:27:40.516572+00');
INSERT INTO public.sections (id, program_id, name, year_level, school_year, semester, created_at) VALUES (20, 9, 'BSIT31C', 3, '2026-2027', 1, '2026-10-25 15:27:40.516572+00');


--
-- Name: sections_id_seq; Type: SEQUENCE SET; Schema: public; Owner: checkmate
--

SELECT pg_catalog.setval('public.sections_id_seq', 20, true);


--
-- PostgreSQL database dump complete
--

\unrestrict gvT28qkBP8aCmhD0xLGzyI9PrOD2WVLuVsoebVeyId6aR2UbKWmTYe3YSKF1rro
