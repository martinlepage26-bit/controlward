-- Read-only catalog inspection. This never calls a queue-claim function.
-- Run with a schema owner account so catalog visibility is complete.
-- Classification identifies a schema family, not full migration compatibility.
WITH columns_seen AS (
    SELECT column_name FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'gap_scores'
), facts AS (
    SELECT to_regclass('public.gap_clusters') IS NOT NULL AS clusters_present,
           to_regclass('public.gap_scores') IS NOT NULL AS scores_present,
           EXISTS (SELECT 1 FROM columns_seen WHERE column_name = 'cluster_id') AS minimal_fk,
           EXISTS (SELECT 1 FROM columns_seen WHERE column_name = 'gap_cluster_id') AS pipeline_fk,
           to_regclass('public.queue_jobs') IS NOT NULL AS queue_present,
           to_regclass('public.extraction_embeddings') IS NOT NULL AS extraction_embeddings_present,
           to_regclass('public.gap_cluster_assessments') IS NOT NULL AS assessments_present,
           EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                   AND table_name = 'review_extractions' AND column_name = 'item_index') AS item_index_present
)
SELECT CASE
           WHEN NOT clusters_present AND NOT scores_present AND NOT queue_present THEN 'empty_or_unrelated'
           WHEN clusters_present AND scores_present AND minimal_fk AND NOT pipeline_fk AND NOT queue_present THEN 'contextward_minimal'
           WHEN clusters_present AND scores_present AND pipeline_fk AND NOT minimal_fk AND queue_present THEN 'gap_pipeline'
           ELSE 'mixed_or_incomplete'
       END AS schema_family,
       facts.*,
       COALESCE((SELECT bool_and(position('#variable_conflict use_column' IN p.prosrc) > 0)
                 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public' AND p.proname = 'claim_queue_jobs'), false) AS queue_claim_ambiguity_fix,
       COALESCE((SELECT bool_and(position('#variable_conflict use_column' IN p.prosrc) > 0)
                 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public' AND p.proname = 'claim_extraction_jobs'), false) AS extraction_claim_ambiguity_fix
FROM facts;
