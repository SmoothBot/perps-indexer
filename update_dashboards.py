#!/usr/bin/env python3
import json
import glob
import re

def update_dashboard(file_path):
    """Update a single dashboard file for the new schema"""
    with open(file_path, 'r') as f:
        content = f.read()
        original_content = content

    # Replace table names
    content = content.replace('hl_fills', 'fills')
    content = content.replace('hl_hourly_user_stats', 'hourly_user_stats')
    content = content.replace('FROM fills', 'FROM fills f JOIN markets m ON f.market_id = m.id')
    content = content.replace('FROM hourly_user_stats', 'FROM hourly_user_stats hus JOIN markets m ON hus.market_id = m.id')

    # Replace coin references with market symbol
    content = re.sub(r'\bcoin\b(?!\s*AS)', 'm.symbol', content)
    content = re.sub(r'DISTINCT coin', 'DISTINCT m.symbol AS coin', content)
    content = re.sub(r"coin = '\$\{coin\}'", "m.symbol = '${coin}'", content)
    content = re.sub(r"coin = '\$coin'", "m.symbol = '$coin'", content)

    # Fix GROUP BY clauses
    content = re.sub(r'GROUP BY coin', 'GROUP BY m.symbol', content)
    content = re.sub(r'GROUP BY ([^,\n]+), coin', r'GROUP BY \1, m.symbol', content)
    content = re.sub(r'ORDER BY ([^,\n]+), coin', r'ORDER BY \1, m.symbol', content)

    # Fix SELECT clauses
    content = re.sub(r'SELECT\s+coin,', 'SELECT m.symbol AS coin,', content)
    content = re.sub(r'SELECT\s+coin\s+AS', 'SELECT m.symbol AS', content)

    # Parse JSON to add market_type variable
    data = json.loads(content)

    # Add market_type variable to templating
    if 'templating' in data and 'list' in data['templating']:
        # Check if market_type variable already exists
        has_market_type = any(var.get('name') == 'market_type' for var in data['templating']['list'])

        if not has_market_type:
            market_type_var = {
                "allValue": "All",
                "current": {
                    "selected": True,
                    "text": "All",
                    "value": "All"
                },
                "datasource": {
                    "type": "postgres",
                    "uid": "${datasource}"
                },
                "definition": "SELECT 'All' AS market_type UNION SELECT 'spot' UNION SELECT 'perp' ORDER BY 1",
                "hide": 0,
                "includeAll": False,
                "label": "Market Type",
                "multi": False,
                "name": "market_type",
                "options": [],
                "query": "SELECT 'All' AS market_type UNION SELECT 'spot' UNION SELECT 'perp' ORDER BY 1",
                "refresh": 1,
                "regex": "",
                "skipUrlSync": False,
                "sort": 0,
                "type": "query"
            }

            # Insert after datasource or at the beginning
            datasource_idx = next((i for i, var in enumerate(data['templating']['list']) if var.get('name') == 'datasource'), -1)
            if datasource_idx >= 0:
                data['templating']['list'].insert(datasource_idx + 1, market_type_var)
            else:
                data['templating']['list'].insert(0, market_type_var)

    # Update panels to include market type filter
    if 'panels' in data:
        for panel in data['panels']:
            if 'targets' in panel:
                for target in panel['targets']:
                    if 'rawSql' in target:
                        # Add market type filter to WHERE clauses
                        sql = target['rawSql']

                        # Add market type filter to queries with WHERE clause
                        if 'WHERE' in sql and 'm.market_type' not in sql:
                            # Find the WHERE clause and add market type filter
                            sql = re.sub(
                                r'(WHERE\s+[^\n]+)',
                                r"\1\n  AND ('${market_type}' = 'All' OR m.market_type = '${market_type}')",
                                sql,
                                count=1
                            )

                        target['rawSql'] = sql

    # Update coin variable query to include market type filter
    if 'templating' in data and 'list' in data['templating']:
        for var in data['templating']['list']:
            if var.get('name') == 'coin':
                var['definition'] = "SELECT 'All' UNION SELECT DISTINCT m.symbol FROM markets m WHERE ('${market_type}' = 'All' OR m.market_type = '${market_type}') ORDER BY 1"
                var['query'] = var['definition']

    # Write the updated dashboard
    with open(file_path, 'w') as f:
        json.dump(data, f, indent=2)

    if content != original_content:
        print(f"Updated {file_path}")
        return True
    return False

def main():
    dashboard_files = glob.glob('/Users/sam/rise/rust-indexer/grafana/provisioning/dashboards/*.json')

    updated_count = 0
    for file_path in dashboard_files:
        print(f"Processing {file_path}...")
        try:
            if update_dashboard(file_path):
                updated_count += 1
        except Exception as e:
            print(f"Error updating {file_path}: {e}")

    print(f"\nUpdated {updated_count} dashboard(s)")

if __name__ == "__main__":
    main()