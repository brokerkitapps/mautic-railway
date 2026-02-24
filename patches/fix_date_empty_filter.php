<?php
/**
 * Fix MySQL 8.0.16+ / 9.4+ error 1525: "Incorrect DATE value: ''"
 *
 * Mautic's segment filter builders generate `WHERE date_col = ''` and
 * `WHERE date_col <> ''` for empty/notEmpty operators. MySQL 8.0.16+
 * rejects these comparisons on DATE/DATETIME columns regardless of sql_mode.
 *
 * Fix: simplify empty → IS NULL, notEmpty → IS NOT NULL.
 * Safe because date columns cannot store empty strings.
 *
 * Upstream: https://github.com/mautic/mautic/issues/10686
 * The fix in PR #11126 only patched SegmentOperatorQuerySubscriber.
 * ComplexRelationValueFilterQueryBuilder and ForeignFuncFilterQueryBuilder
 * were not fixed.
 */

$patches = [
    // Patch 1: ComplexRelationValueFilterQueryBuilder (company fields via JOIN)
    [
        'file' => '/var/www/html/docroot/app/bundles/LeadBundle/Segment/Query/Filter/ComplexRelationValueFilterQueryBuilder.php',
        'replacements' => [
            // empty: CompositeExpression(OR, [isNull, eq('')]) → isNull only
            [
                'search'  => "case 'empty':\n" .
                    "                \$expression = new CompositeExpression(CompositeExpression::TYPE_OR,\n" .
                    "                    [\n" .
                    "                        \$queryBuilder->expr()->isNull(\$tableAlias.'.'.\$filter->getField()),\n" .
                    "                        \$queryBuilder->expr()->eq(\$tableAlias.'.'.\$filter->getField(), \$queryBuilder->expr()->literal('')),\n" .
                    "                    ]\n" .
                    "                );\n" .
                    "                break;",
                'replace' => "case 'empty':\n" .
                    "                \$expression = \$queryBuilder->expr()->isNull(\$tableAlias.'.'.\$filter->getField());\n" .
                    "                break;",
            ],
            // notEmpty: CompositeExpression(AND, [isNotNull, neq('')]) → isNotNull only
            [
                'search'  => "case 'notEmpty':\n" .
                    "                \$expression = new CompositeExpression(CompositeExpression::TYPE_AND,\n" .
                    "                    [\n" .
                    "                        \$queryBuilder->expr()->isNotNull(\$tableAlias.'.'.\$filter->getField()),\n" .
                    "                        \$queryBuilder->expr()->neq(\$tableAlias.'.'.\$filter->getField(), \$queryBuilder->expr()->literal('')),\n" .
                    "                    ]\n" .
                    "                );\n" .
                    "                break;",
                'replace' => "case 'notEmpty':\n" .
                    "                \$expression = \$queryBuilder->expr()->isNotNull(\$tableAlias.'.'.\$filter->getField());\n" .
                    "                break;",
            ],
        ],
    ],

    // Patch 2: ForeignFuncFilterQueryBuilder (aggregate function fields)
    [
        'file' => '/var/www/html/docroot/app/bundles/LeadBundle/Segment/Query/Filter/ForeignFuncFilterQueryBuilder.php',
        'replacements' => [
            // empty: or(isNull, eq(:param='')) → isNull only
            [
                'search'  => "case 'empty':\n" .
                    "                \$expression = \$queryBuilder->expr()->or(\n" .
                    "                    \$queryBuilder->expr()->isNull(\$tableAlias.'.'.\$filter->getField()),\n" .
                    "                    \$queryBuilder->expr()->eq(\$tableAlias.'.'.\$filter->getField(), ':'.\$emptyParameter = \$this->generateRandomParameterName())\n" .
                    "                );\n" .
                    "                \$queryBuilder->setParameter(\$emptyParameter, '');\n" .
                    "                break;",
                'replace' => "case 'empty':\n" .
                    "                \$expression = \$queryBuilder->expr()->isNull(\$tableAlias.'.'.\$filter->getField());\n" .
                    "                break;",
            ],
            // notEmpty: and(isNotNull, neq(:param='')) → isNotNull only
            [
                'search'  => "case 'notEmpty':\n" .
                    "                \$expression = \$queryBuilder->expr()->and(\n" .
                    "                    \$queryBuilder->expr()->isNotNull(\$tableAlias.'.'.\$filter->getField()),\n" .
                    "                    \$queryBuilder->expr()->neq(\$tableAlias.'.'.\$filter->getField(), ':'.\$emptyParameter = \$this->generateRandomParameterName())\n" .
                    "                );\n" .
                    "                \$queryBuilder->setParameter(\$emptyParameter, '');\n" .
                    "                break;",
                'replace' => "case 'notEmpty':\n" .
                    "                \$expression = \$queryBuilder->expr()->isNotNull(\$tableAlias.'.'.\$filter->getField());\n" .
                    "                break;",
            ],
        ],
    ],
];

$errors = 0;
foreach ($patches as $patch) {
    $file = $patch['file'];
    if (!file_exists($file)) {
        fwrite(STDERR, "ERROR: File not found: $file\n");
        $errors++;
        continue;
    }

    $content = file_get_contents($file);
    $applied = 0;

    foreach ($patch['replacements'] as $r) {
        $count = 0;
        $content = str_replace($r['search'], $r['replace'], $content, $count);
        if ($count === 0) {
            fwrite(STDERR, "WARNING: Pattern not found in $file (may already be patched)\n");
        }
        $applied += $count;
    }

    if ($applied > 0) {
        file_put_contents($file, $content);
        echo "Patched $file ($applied replacements)\n";
    } else {
        fwrite(STDERR, "ERROR: No replacements made in $file\n");
        $errors++;
    }
}

if ($errors > 0) {
    fwrite(STDERR, "PATCH FAILED: $errors file(s) had errors\n");
    exit(1);
}

echo "All date empty/notEmpty patches applied successfully\n";
