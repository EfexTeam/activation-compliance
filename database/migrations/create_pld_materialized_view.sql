-- ==============================================================================
-- SCRIPT: create_pld_materialized_view.sql
-- DESCRIPCIÓN: Vista materializada y optimización para screening periódico de PLD.
-- AUTOR: Pablo Ochoa
-- FECHA: 2026-01-30
-- ==============================================================================

-- 1. LIMPIEZA INICIAL
-- Eliminamos la vista previa para asegurar una creación limpia de índices y estructura.
DROP MATERIALIZED VIEW IF EXISTS pld_subjects_for_screening CASCADE;

-- 2. DEFINICIÓN DE LA VISTA
CREATE MATERIALIZED VIEW pld_subjects_for_screening AS
WITH 
-- 1. Catálogos para mapeo de países normalizado (ISO 2 letras)
country_lookup AS (
    SELECT id, country_key FROM enterprise_nationalitycountry
    UNION
    SELECT id, iso_code FROM enterprise_luisocountry
),

-- 2. Consolidación de todos los sujetos (Unión Completa)
raw_subjects AS (
    -- ENTERPRISE (La entidad principal)
    SELECT 
        id AS enterprise_id, id AS subject_id, 'ENTERPRISE' AS subject_type,
        NULL::integer AS related_person_id, NULL::integer AS stakeholder_id, NULL::integer AS natural_person_id,
        name AS raw_name, '' AS first_name, '' AS last_name, '' AS second_last_name,
        country, rfc, tax_id, NULL AS curp, NULL AS ssn, NULL AS document_number, NULL AS document_type,
        is_full_register, is_kyc, enterprise_operational_status_id, created_at, updated_at
    FROM enterprise_enterprise
    WHERE is_active = true AND enterprise_operational_status_id = 2

    UNION ALL

    -- STAKEHOLDERS (Accionistas y Representantes en tabla antigua/legacy)
    SELECT 
        s.enterprise_id, s.id, 
        CASE 
            WHEN LOWER(s.title) ~ '(representante|apoderado|power|legal)' THEN 'LEGAL_REP'
            WHEN LOWER(s.title) ~ '(accionista|shareholder|socio|partner)' THEN 'SHAREHOLDER'
            ELSE 'STAKEHOLDER'
        END,
        NULL, s.id, NULL,
        s.name, s.name, s.last_name, s.second_last_name,
        COALESCE(c1.country_key, c2.country_key, 'MX'), NULL, NULL, s.curp, s.ssn, s.number_id, NULL,
        NULL, NULL, e.enterprise_operational_status_id, s.created_at, s.updated_at
    FROM enterprise_stakeholders s
    JOIN enterprise_enterprise e ON s.enterprise_id = e.id
    LEFT JOIN country_lookup c1 ON s.nationality_country_id = c1.id
    LEFT JOIN country_lookup c2 ON s.country_birth_id = c2.id
    WHERE s.is_active = true AND s.origin_type = 'PERSON' AND e.is_active = true

    UNION ALL

    -- NATURAL PERSONS (Representantes y Accionistas tabla nueva)
    SELECT 
        npe.enterprise_id, np.id,
        CASE WHEN (np.representative_position IS NOT NULL AND np.representative_position != '') THEN 'LEGAL_REP' ELSE 'SHAREHOLDER' END,
        np.id, NULL, np.id,
        first_name, first_name, last_name, second_last_name,
        COALESCE(np.country, c.country_key, 'MX'), NULL, NULL, np.curp, NULL, np.document_number, np.document_type,
        np.is_full_register, np.is_kyc, e.enterprise_operational_status_id, np.created_at, np.updated_at
    FROM enterprise_naturalperson np
    JOIN enterprise_naturalpersonenterprise npe ON np.id = npe.natural_person_id
    JOIN enterprise_enterprise e ON npe.enterprise_id = e.id
    LEFT JOIN country_lookup c ON np.iso_country_id = c.id
    WHERE npe.is_active = true AND e.is_active = true

    UNION ALL

    -- BENEFICIARIES (Contactos marcados como beneficiarios)
    SELECT 
        c.enterprise_id, c.id, 'BENEFICIARY',
        np.id, NULL, np.id,
        np.first_name, np.first_name, np.last_name, np.second_last_name,
        COALESCE(np.country, cl.country_key, 'MX'), NULL, NULL, np.curp, NULL, np.document_number, np.document_type,
        np.is_full_register, np.is_kyc, e.enterprise_operational_status_id, c.created_at, c.updated_at
    FROM enterprise_contact c
    JOIN enterprise_naturalpersonenterprise npe ON c.natural_person_enterprise_id = npe.id
    JOIN enterprise_naturalperson np ON npe.natural_person_id = np.id
    JOIN enterprise_enterprise e ON c.enterprise_id = e.id
    LEFT JOIN country_lookup cl ON np.iso_country_id = cl.id
    WHERE c.is_active = true AND c.beneficiary_relationship_id IS NOT NULL
)

-- 3. Transformación Final y Reglas de Negocio Centralizadas
SELECT 
    enterprise_id, 
    subject_id, 
    subject_type,
    related_person_id, 
    stakeholder_id, 
    natural_person_id,
    
    UPPER(TRIM(raw_name)) AS name,
    UPPER(TRIM(COALESCE(first_name, ''))) AS first_name,
    UPPER(TRIM(COALESCE(last_name, ''))) AS last_name,
    UPPER(TRIM(COALESCE(second_last_name, ''))) AS second_last_name,
    country,

    -- Determinación de tipo de documento según país (Normalización para API)
    CASE 
        WHEN country = 'MX' THEN (CASE WHEN subject_type = 'ENTERPRISE' THEN 'RFC' ELSE 'CURP' END)
        WHEN country = 'US' THEN (CASE WHEN subject_type = 'ENTERPRISE' THEN 'TAX_ID' ELSE 'SSN' END)
        ELSE COALESCE(NULLIF(document_type, ''), 'PASSPORT')
    END AS document_id_type,

    -- Limpieza extrema de valor de documento (Remueve caracteres especiales)
    REGEXP_REPLACE(UPPER(TRIM(
        CASE 
            WHEN country = 'MX' THEN COALESCE(NULLIF(rfc, ''), NULLIF(curp, ''), '')
            WHEN country = 'US' THEN COALESCE(NULLIF(tax_id, ''), NULLIF(ssn, ''), '')
            ELSE COALESCE(NULLIF(document_number, ''), NULLIF(rfc, ''), NULLIF(tax_id, ''), '')
        END
    )), '[^A-Z0-9]', '', 'g') AS document_id_value,

    -- Flag is_pld_ready: Crucial para filtrar envíos a la API
    (CASE 
        WHEN country IS NOT NULL 
             AND (CASE 
                    WHEN subject_type = 'ENTERPRISE' THEN (raw_name IS NOT NULL AND TRIM(raw_name) != '') 
                    ELSE (first_name IS NOT NULL AND TRIM(first_name) != '' AND last_name IS NOT NULL AND TRIM(last_name) != '') 
                  END)
             AND LENGTH(REGEXP_REPLACE(UPPER(TRIM(
                 CASE 
                    WHEN country = 'MX' THEN COALESCE(rfc, curp, '')
                    WHEN country = 'US' THEN COALESCE(tax_id, ssn, '')
                    ELSE COALESCE(document_number, rfc, tax_id, '')
                 END
             )), '[^A-Z0-9]', '', 'g')) >= 9 -- Validamos IDs con longitud mínima oficial
        THEN TRUE ELSE FALSE 
    END) AS is_pld_ready,

    is_full_register, 
    is_kyc, 
    enterprise_operational_status_id,
    created_at, 
    updated_at,
    NOW() AS view_refreshed_at
FROM raw_subjects;

-- 4. ÍNDICES PARA PERFORMANCE Y REFRESH CONCURRENTLY
-- OBLIGATORIO: Permite REFRESH CONCURRENTLY (actualización sin bloqueos)
CREATE UNIQUE INDEX idx_pld_subjects_unique_pk ON pld_subjects_for_screening (enterprise_id, subject_type, subject_id);

-- OPTIMIZACIÓN: Acelera la consulta de la Step Function
CREATE INDEX idx_pld_ready_filter ON pld_subjects_for_screening (is_pld_ready) WHERE is_pld_ready = TRUE;

-- AUDITORÍA: Acelera búsquedas por documento
CREATE INDEX idx_pld_document_search ON pld_subjects_for_screening (document_id_value);