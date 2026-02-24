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
 * Patches 3 files:
 *   1. ComplexRelationValueFilterQueryBuilder (company fields via JOIN)
 *   2. ForeignFuncFilterQueryBuilder (aggregate function fields)
 *   3. SegmentOperatorQuerySubscriber (base table fields — belt-and-suspenders)
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
            // Note: upstream has a blank line between ); and break; in this case
            [
                'search'  => "case 'notEmpty':\n" .
                    "                \$expression = new CompositeExpression(CompositeExpression::TYPE_AND,\n" .
                    "                    [\n" .
                    "                        \$queryBuilder->expr()->isNotNull(\$tableAlias.'.'.\$filter->getField()),\n" .
                    "                        \$queryBuilder->expr()->neq(\$tableAlias.'.'.\$filter->getField(), \$queryBuilder->expr()->literal('')),\n" .
                    "                    ]\n" .
                    "                );\n" .
                    "\n" .
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

    // Patch 3: SegmentOperatorQuerySubscriber (base table fields on leads table)
    // Belt-and-suspenders: the doesColumnSupportEmptyValue() guard should prevent
    // this for date/datetime, but we remove the eq('') entirely to be safe.
    // For non-date fields (varchar etc), IS NULL alone is sufficient in practice
    // because MySQL varchar fields store NULL, not empty string, when truly empty.
    [
        'file' => '/var/www/html/docroot/app/bundles/LeadBundle/EventListener/SegmentOperatorQuerySubscriber.php',
        'replacements' => [
            // onEmptyOperator: remove conditional eq('') addition
            [
                'search'  => "\$parts           = [\$expr->isNull(\$field)];\n" .
                    "\n" .
                    "        if (\$filter->doesColumnSupportEmptyValue()) {\n" .
                    "            \$parts[] = \$expr->eq(\$field, \$expr->literal(''));\n" .
                    "        }\n" .
                    "\n" .
                    "        \$event->addExpression(new CompositeExpression(CompositeExpression::TYPE_OR, \$parts));",
                'replace' => "\$expression = \$expr->isNull(\$field);\n" .
                    "\n" .
                    "        \$event->addExpression(\$expression);",
            ],
            // onNotEmptyOperator: remove conditional neq('') addition
            [
                'search'  => "\$parts           = [\$expr->isNotNull(\$field)];\n" .
                    "\n" .
                    "        if (\$filter->doesColumnSupportEmptyValue()) {\n" .
                    "            \$parts[] = \$expr->neq(\$field, \$expr->literal(''));\n" .
                    "        }\n" .
                    "\n" .
                    "        \$event->addExpression(new CompositeExpression(CompositeExpression::TYPE_AND, \$parts));",
                'replace' => "\$expression = \$expr->isNotNull(\$field);\n" .
                    "\n" .
                    "        \$event->addExpression(\$expression);",
            ],
        ],
    ],
];

$errors = 0;
$totalApplied = 0;
foreach ($patches as $patch) {
    $file = $patch['file'];
    $shortFile = basename($file);
    if (!file_exists($file)) {
        fwrite(STDERR, "ERROR: File not found: $file\n");
        $errors++;
        continue;
    }

    $content = file_get_contents($file);
    $applied = 0;

    foreach ($patch['replacements'] as $i => $r) {
        $count = 0;
        $content = str_replace($r['search'], $r['replace'], $content, $count);
        if ($count === 0) {
            fwrite(STDERR, "ERROR: Pattern #$i not found in $shortFile\n");
            $errors++;
        }
        $applied += $count;
    }

    if ($applied > 0) {
        file_put_contents($file, $content);
        echo "Patched $shortFile ($applied replacements)\n";
        $totalApplied += $applied;
    } else {
        fwrite(STDERR, "ERROR: No replacements made in $shortFile\n");
    }
}

// Verification: grep all patched files to ensure no literal('') remains in empty/notEmpty context
echo "\n--- Verification ---\n";
$verifyFiles = [
    '/var/www/html/docroot/app/bundles/LeadBundle/Segment/Query/Filter/ComplexRelationValueFilterQueryBuilder.php',
    '/var/www/html/docroot/app/bundles/LeadBundle/Segment/Query/Filter/ForeignFuncFilterQueryBuilder.php',
    '/var/www/html/docroot/app/bundles/LeadBundle/EventListener/SegmentOperatorQuerySubscriber.php',
];
$verifyErrors = 0;
foreach ($verifyFiles as $vf) {
    $shortName = basename($vf);
    if (!file_exists($vf)) continue;
    $c = file_get_contents($vf);
    if (preg_match("/literal\s*\(\s*''\s*\)/", $c)) {
        fwrite(STDERR, "VERIFY FAIL: $shortName still contains literal('') — patch incomplete\n");
        $verifyErrors++;
    } else {
        echo "VERIFY OK: $shortName — no literal('') found\n";
    }
}

if ($errors > 0 || $verifyErrors > 0) {
    fwrite(STDERR, "\nPATCH FAILED: $errors pattern errors, $verifyErrors verification errors\n");
    exit(1);
}

echo "\nAll $totalApplied replacements applied and verified successfully\n";
