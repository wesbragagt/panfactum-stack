#!/usr/bin/env python3
"""Evaluate actual module expressions with mocked kubectl and fixture child outputs.

No cluster, state, Terragrunt or cloud calls. The harness copies production blocks;
only child outputs, resource dependencies and the generated cluster ID are fixtures.
Run: python3 tests/test_pooler_render.py [--baseline-main /path/main.tf]
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import tomllib

MODULE = Path(__file__).resolve().parents[1]


def blocks(source):
    starts = list(re.finditer(r'(?m)^(?:terraform|locals|resource|module|variable|output|data|moved)\b[^\n]*', source))
    return [source[m.start():starts[i + 1].start() if i + 1 < len(starts) else len(source)] for i, m in enumerate(starts)]


def harness(root, main):
    root.mkdir()
    chunks = blocks(main)
    selected = [next(b for b in chunks if b.startswith('locals {'))]
    for name in ['connection_pooler', 'vpa_pooler', 'pdb_pooler']:
        selected.append(next(b for b in chunks if b.startswith(f'resource "kubectl_manifest" "{name}"')))
    snapshots = []
    for block in selected[1:]:
        name = re.search(r'resource "kubectl_manifest" "([^\"]+)"', block).group(1)
        iterable = re.search(r'  for_each\s*=\s*([^\n]+)', block).group(1)
        body = re.search(r'  yaml_body\s*=\s*(.*?)(?=\n  force_conflicts)', block, re.S).group(1)
        body = body.replace('each.key', 'fixture_key').replace('each.value', 'fixture_key')
        snapshots.append('locals { snapshot_' + name + ' = {for fixture_key in ' + iterable + ': fixture_key => yamldecode(' + body + ')} }')
    job = next(b for b in chunks if b.startswith('module "schema_init_job"'))
    job_count = re.search(r'  count\s*=\s*([^\n]+)', job).group(1)
    job_name = re.search(r'  name\s*=\s*([^\n]+)', job).group(1)
    snapshots.append('locals {\n snapshot_job_count = ' + job_count + '\n snapshot_job_name = ' + job_name + '\n }')
    for name in ['reader', 'admin', 'schema_reader', 'schema_admin']:
        block = next(b for b in chunks if b.startswith(f'resource "vault_database_secret_backend_role" "{name}"'))
        expression = re.search(r'  creation_statements\s*=\s*(.*?)(?=\n  renew_statements)', block, re.S).group(1)
        expression = expression.replace('each.key', '"one"')
        snapshots.append('locals {\n snapshot_lease_' + name + ' = ' + expression + '\n }')
    selected += snapshots
    selected += [b for b in blocks((MODULE / 'rustybouncer.tf').read_text()) if not b.startswith('module ')]
    text = '\n'.join(selected)
    text = re.sub(r'(?m)^\s*depends_on\s*=.*\n', '\n', text)
    text = text.replace('random_id.cluster_id.hex', '"pg-test"')
    text = text.replace('data.pf_kube_labels.labels.labels', 'local.test_labels')
    (root / 'main.tf').write_text(text)
    shutil.copy(MODULE / 'vars.tf', root / 'vars.tf')
    shutil.copy(MODULE / 'rustybouncer_vars.tf', root / 'rustybouncer_vars.tf')
    stub = root / 'stub'
    stub.mkdir()
    (stub / 'main.tf').write_text('''
output "labels" { value = { app = "pooler" } }
output "match_labels" { value = { app = "pooler" } }
output "secret_name" { value = "fixture-certificate" }
output "scheduler_name" { value = "default-scheduler" }
output "workload_important_priority_class_name" { value = "workload-important" }
output "topology_spread_constraints" { value = [] }
output "tolerations" { value = [] }
output "affinity" { value = {} }
output "github_registry" { value = "ghcr.io" }
output "disruption_window_id" { value = "test-window" }
''')
    (root / 'fixtures.tf').write_text('''
terraform {
  required_providers {
    kubectl = { source = "alekc/kubectl", version = "3.0.1" }
  }
}
locals { test_labels = { app = "pooler" } }
module "util_pooler" {
  for_each = toset(["r", "rw"])
  source = "./stub"
}
module "util_cluster" { source = "./stub" }
module "constants" { source = "./stub" }
module "pull_through" { source = "./stub" }
module "server_certs" { source = "./stub" }
module "pooler_certs" { source = "./stub" }
module "rustybouncer_certs" {
  count = var.pooler_implementation == "rustybouncer" ? 1 : 0
  source = "./stub"
}
module "disruption_window_controller" {
  count = var.voluntary_disruption_window_enabled ? 1 : 0
  source = "./stub"
}
output "default_contract" {
  sensitive = true
  value = {
    poolers = {for k,v in kubectl_manifest.connection_pooler : k => yamldecode(v.yaml_body)}
    vpa = {for k,v in kubectl_manifest.vpa_pooler : k => yamldecode(v.yaml_body)}
    pdb = {for k,v in kubectl_manifest.pdb_pooler : k => yamldecode(v.yaml_body)}
    sql = local.schema_init_sql_command
  }
}
output "rust_contract" {
  sensitive = true
  value = {
    deployments = local.rustybouncer_deployments
    config = local.rustybouncer_config
    sql = local.schema_init_sql_command
    services = {for k,v in kubectl_manifest.rustybouncer_service : k => yamldecode(v.yaml_body)}
    monitors = {for k,v in kubectl_manifest.rustybouncer_monitor : k => yamldecode(v.yaml_body)}
    vpa = {for k,v in kubectl_manifest.vpa_pooler : k => yamldecode(v.yaml_body)}
  }
}
''')
    testdir = root / 'tests'
    testdir.mkdir()
    (testdir / 'render.tftest.hcl').write_text('''
mock_provider "kubectl" {}
variables {
  aws_iam_ip_allow_list = []
  pg_cluster_namespace = "fixture"
  extra_schemas = ["one"]
}
run "default" {
  command = plan
  assert {
    condition = length(kubectl_manifest.connection_pooler) == 1 && length(kubectl_manifest.rustybouncer) == 0 && length(kubectl_manifest.rustybouncer_config) == 0 && length(kubectl_manifest.rustybouncer_service) == 0 && length(kubectl_manifest.rustybouncer_monitor) == 0
    error_message = "Default must retain the existing CNPG Pooler and no RustyBouncer resources."
  }
}
run "rust" {
  command = plan
  variables {
    pooler_implementation = "rustybouncer"
    pgbouncer_read_only_enabled = false
    rustybouncer_image = "registry.example/rustybouncer@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  assert {
    condition = length(kubectl_manifest.connection_pooler) == 0 && length(kubectl_manifest.rustybouncer) == 1 && length(kubectl_manifest.rustybouncer_service) == 1
    error_message = "RustyBouncer must independently own just the writable endpoint."
  }
  assert {
    condition = yamldecode(kubectl_manifest.vpa_pooler["rw"].yaml_body).spec.targetRef.kind == "Deployment" && yamldecode(kubectl_manifest.vpa_pooler["rw"].yaml_body).spec.resourcePolicy.containerPolicies[0].containerName == "rustybouncer"
    error_message = "VPA must target the actual implementation."
  }
}
run "rust_disabled_endpoints" {
  command = plan
  variables {
    pooler_implementation = "rustybouncer"
    pgbouncer_read_only_enabled = false
    pgbouncer_read_write_enabled = false
    vpa_enabled = false
    rustybouncer_image = "registry.example/rustybouncer@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  assert {
    condition = length(kubectl_manifest.rustybouncer) == 0 && length(kubectl_manifest.rustybouncer_service) == 0 && length(kubectl_manifest.vpa_pooler) == 0
    error_message = "Disabled endpoints/VPA must not create resources."
  }
}
run "rust_transaction" {
  command = plan
  variables {
    pooler_implementation = "rustybouncer"
    pgbouncer_read_only_enabled = false
    monitoring_enabled = false
    rustybouncer_image = "registry.example/rustybouncer@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    rustybouncer_config = {pool_mode = "transaction"}
  }
  assert {
    condition = length(kubectl_manifest.rustybouncer_monitor) == 0 && strcontains(local.rustybouncer_config, "transaction")
    error_message = "Transaction mode must render and monitoring must be optional."
  }
}
run "missing_image" {
  command = plan
  variables {
    pooler_implementation = "rustybouncer"
    pgbouncer_read_only_enabled = false
  }
  expect_failures = [kubectl_manifest.rustybouncer_config]
}
run "replica_only_rejected" {
  command = plan
  variables {
    pooler_implementation = "rustybouncer"
    pgbouncer_read_only_enabled = true
    rustybouncer_image = "registry.example/rustybouncer@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  expect_failures = [kubectl_manifest.rustybouncer_config]
}
run "mutable_image_rejected" {
  command = plan
  variables { rustybouncer_image = "registry.example/rustybouncer:latest" }
  expect_failures = [var.rustybouncer_image]
}
run "invalid_implementation_rejected" {
  command = plan
  variables { pooler_implementation = "other" }
  expect_failures = [var.pooler_implementation]
}
run "statement_rejected" {
  command = plan
  variables { rustybouncer_config = {pool_mode = "statement"} }
  expect_failures = [var.rustybouncer_config]
}
run "invalid_size_rejected" {
  command = plan
  variables { rustybouncer_config = {pool_size = 0} }
  expect_failures = [var.rustybouncer_config]
}
run "fraction_rejected" {
  command = plan
  variables { rustybouncer_config = {probe_timeout_ms = 1.5} }
  expect_failures = [var.rustybouncer_config]
}
''')


def run(root, *args, input=None):
    result = subprocess.run(['tofu', f'-chdir={root}', *args], input=input, text=True, capture_output=True, env={**os.environ, 'TF_IN_AUTOMATION': '1'})
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def evaluate(root, expression, variables=None):
    (root / 'terraform.tfvars.json').write_text(json.dumps({'aws_iam_ip_allow_list': [], 'pg_cluster_namespace': 'fixture', 'extra_schemas': ['one'], **(variables or {})}))
    return json.loads(json.loads(run(root, 'console', '-no-color', input=f'nonsensitive(jsonencode({expression}))\n')))


def check_rust(root):
    contract = evaluate(root, '{deployments=local.rustybouncer_deployments,config=local.rustybouncer_config,sql=local.schema_init_sql_command,job_count=local.snapshot_job_count,job_name=local.snapshot_job_name}', {
        'pooler_implementation': 'rustybouncer', 'pgbouncer_read_only_enabled': False,
        'rustybouncer_image': 'registry.example/rustybouncer@sha256:' + 'a' * 64,
    })
    config = tomllib.loads(contract['config'])
    assert config['pool_mode'] == 'session' and config['read_max_attempts'] == 1
    assert config['nodes'] == [{'name': 'cnpg-primary', 'host': 'pg-test-rw.fixture.svc', 'tls_server_name': 'pg-test-rw.fixture.svc', 'port': 5432}]
    assert config['auth_query']['user'] == 'rustybouncer_auth'
    assert config['probe_user'] == 'rustybouncer_auth'
    assert 'password' not in config and 'probe_password_env' not in config
    assert config['backend_tls']['ca_file'] == '/tls/ca/ca.crt'
    deployment = contract['deployments']['rw']
    assert deployment['metadata']['annotations']['reloader.stakater.com/auto'] == 'false'
    pod = deployment['spec']['template']['spec']
    router, probe = pod['containers']
    assert router['args'] == ['/config/rustybouncer.toml']
    assert router['ports'][0]['containerPort'] == 5432
    assert all(m['name'] != 'probe-creds' for m in router['volumeMounts'])
    assert all(m['name'] != 'client-tls' for m in probe['volumeMounts'])
    assert all('subPath' not in m for c in pod['containers'] for m in c['volumeMounts'])
    command = probe['readinessProbe']['exec']['command'][2]
    assert 'hostaddr=127.0.0.1' in command and 'sslmode=verify-full' in command and 'SELECT 1' in command
    assert '$(cat /probe-creds/password)' in command
    ca = next(v for v in pod['volumes'] if v['name'] == 'backend-ca')
    assert ca['secret']['items'] == [{'key': 'ca.crt', 'path': 'ca.crt'}]
    assert 'rolcanlogin AND (rolvaliduntil IS NULL OR rolvaliduntil > CURRENT_TIMESTAMP)' in contract['sql']
    assert 'SECURITY DEFINER SET search_path = pg_catalog' in contract['sql']
    assert contract['sql'].rfind('REVOKE ALL ON FUNCTION public.rustybouncer_user_search') > contract['sql'].rfind('GRANT EXECUTE ON ALL FUNCTIONS')
    assert 'reader_one, writer_one;' in contract['sql']
    assert 'OWNER TO postgres;' in contract['sql']
    assert evaluate(root, 'local.snapshot_job_count', {'pooler_implementation': 'rustybouncer', 'extra_schemas': [], 'pgbouncer_read_only_enabled': False, 'rustybouncer_image': 'registry.example/rustybouncer@sha256:' + 'a' * 64}) == 1
    for name in ['reader', 'admin', 'schema_reader', 'schema_admin']:
        default = evaluate(root, 'local.snapshot_lease_' + name)
        rust = evaluate(root, 'local.snapshot_lease_' + name, {'pooler_implementation': 'rustybouncer'})
        assert rust[:-1] == default, name
        assert rust[-1].startswith('DO $credentials$ BEGIN IF pg_catalog.to_regprocedure('), name
        assert 'public.rustybouncer_user_search(text)' in rust[-1] and 'public.user_search(text)' in rust[-1]
        assert 'PUBLIC, reader, writer, reader_one, writer_one;' in rust[-1]



def check_sql(root, postgres_bin):
    """Run only a private Unix-socket PostgreSQL fixture; never use kubeconfig/cloud."""
    postgres_bin = postgres_bin.resolve()
    variables = {
        'pooler_implementation': 'rustybouncer',
        'pgbouncer_read_only_enabled': False,
        'rustybouncer_image': 'registry.example/rustybouncer@sha256:' + 'a' * 64,
        'extra_schemas': ['one'],
    }
    command = evaluate(root, 'local.schema_init_sql_command', variables)
    sql = command.split("<<'EOSQL'\n", 1)[1].rsplit('\nEOSQL', 1)[0]
    with tempfile.TemporaryDirectory(prefix='rustybouncer-sql-') as tmp:
        data = Path(tmp) / 'data'
        sock = Path(tmp) / 'socket'
        sock.mkdir()
        env = {**os.environ, 'PGHOST': str(sock), 'PGPORT': '5432', 'PGUSER': 'postgres', 'PGDATABASE': 'postgres'}

        def pg(program, *args, input=None, success=True):
            result = subprocess.run([str(postgres_bin / program), *args], input=input, text=True, capture_output=True, env=env)
            if (result.returncode == 0) != success:
                raise RuntimeError(result.stdout + result.stderr)
            return result.stdout.strip()

        def query(sql, success=True):
            return pg('psql', '-X', '-w', '-v', 'ON_ERROR_STOP=1', '-At', input=sql, success=success)

        pg('initdb', '-D', str(data), '-U', 'postgres', '-A', 'trust', '--no-locale')
        pg('pg_ctl', '-D', str(data), '-l', str(Path(tmp) / 'postgres.log'), '-o', f"-k {sock} -c listen_addresses=''", '-w', 'start')
        try:
            query('CREATE DATABASE app; CREATE ROLE reader; CREATE ROLE writer;')
            env['PGDATABASE'] = 'app'
            # Credential issuance can precede either verifier function on fresh bootstrap.
            restriction = evaluate(root, 'local.rustybouncer_lease_sql_restrictions', variables)
            query('CREATE ROLE reader_one; CREATE ROLE writer_one;')
            query(restriction)
            query(sql)
            query(sql)  # Fresh initialization and repeated execution must both work.
            # Older module/bootstrap sources already contain a verifier function.
            query("CREATE FUNCTION public.user_search(text) RETURNS TABLE(usename text, passwd text) LANGUAGE sql SECURITY DEFINER AS 'SELECT rolname::text, rolpassword FROM pg_catalog.pg_authid WHERE rolname=$1';")
            query(sql)
            # Replay each actual credential grant sequence after initialization.
            # Vault substitutes these placeholders and executes them transactionally.
            for index, name in enumerate(['reader', 'admin', 'schema_reader', 'schema_admin']):
                statements = evaluate(root, 'local.snapshot_lease_' + name, variables)
                statements = [s.replace('{{name}}', f'lease_{index}').replace('{{password}}', 'synthetic-fixture').replace('{{expiration}}', 'infinity') for s in statements]
                query('BEGIN;\n' + '\n'.join(statements) + '\nCOMMIT;')
                assert query("SELECT has_function_privilege(r, f, 'EXECUTE') FROM unnest(ARRAY['reader','writer','reader_one','writer_one']) r CROSS JOIN unnest(ARRAY['public.user_search(text)','public.rustybouncer_user_search(text)']) f;").splitlines() == ['f'] * 8
            assert query("SELECT pg_get_userbyid(proowner), array_to_string(proconfig, ',') FROM pg_proc WHERE oid='public.rustybouncer_user_search(text)'::regprocedure;") == 'postgres|search_path=pg_catalog'
            assert query("SELECT has_function_privilege('reader', 'public.user_search(text)', 'EXECUTE'), has_function_privilege('writer_one', 'public.user_search(text)', 'EXECUTE');") == 'f|f' 
            query("CREATE ROLE test_valid LOGIN PASSWORD 'synthetic-fixture'; CREATE ROLE test_expired LOGIN PASSWORD 'synthetic-fixture' VALID UNTIL '2000-01-01'; CREATE ROLE test_disabled NOLOGIN PASSWORD 'synthetic-fixture';")
            checks = query("""
SELECT has_function_privilege('rustybouncer_auth', 'public.rustybouncer_user_search(text)', 'EXECUTE');
SELECT has_function_privilege('reader', 'public.rustybouncer_user_search(text)', 'EXECUTE');
SELECT has_function_privilege('writer', 'public.rustybouncer_user_search(text)', 'EXECUTE');
SELECT has_function_privilege('reader_one', 'public.rustybouncer_user_search(text)', 'EXECUTE');
SELECT has_function_privilege('writer_one', 'public.rustybouncer_user_search(text)', 'EXECUTE');
SET ROLE rustybouncer_auth;
SELECT count(*) FROM public.rustybouncer_user_search('test_valid');
SELECT count(*) FROM public.rustybouncer_user_search('test_expired');
SELECT count(*) FROM public.rustybouncer_user_search('test_disabled');
SELECT count(*) FROM public.rustybouncer_user_search('missing_role');
""")
            assert checks.splitlines() == ['t', 'f', 'f', 'f', 'f', 'SET', '1', '0', '0', '0'], checks
            query('SET ROLE rustybouncer_auth; SELECT rolpassword FROM pg_catalog.pg_authid;', success=False)
            query("SET ROLE reader; SELECT * FROM public.rustybouncer_user_search('test_valid');", success=False)
            query("ALTER ROLE test_valid NOLOGIN;")
            assert query("SET ROLE rustybouncer_auth; SELECT count(*) FROM public.rustybouncer_user_search('test_valid');").splitlines()[-1] == '0'
            print('Private PostgreSQL fixture: fresh/repeated initialization, verifier privilege isolation, expiry, NOLOGIN and missing-role rejection passed.')
        finally:
            pg('pg_ctl', '-D', str(data), '-m', 'immediate', '-w', 'stop')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline-main', type=Path)
    parser.add_argument('--postgres-bin', type=Path, help='Run private PostgreSQL role/function checks using this bin directory.')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='rustybouncer-render-') as tmp:
        current = Path(tmp) / 'current'
        harness(current, (MODULE / 'main.tf').read_text())
        run(current, 'init', '-backend=false', '-input=false', '-no-color')
        print(run(current, 'test', '-no-color'))
        check_rust(current)
        if args.postgres_bin:
            check_sql(current, args.postgres_bin)
        if args.baseline_main:
            baseline = Path(tmp) / 'baseline'
            harness(baseline, args.baseline_main.read_text())
            run(baseline, 'init', '-backend=false', '-input=false', '-no-color')
            expression = '{poolers=local.snapshot_connection_pooler,vpa=local.snapshot_vpa_pooler,pdb=local.snapshot_pdb_pooler,sql=local.schema_init_sql_command,job_count=local.snapshot_job_count,job_name=local.snapshot_job_name,reader_lease=local.snapshot_lease_reader,admin_lease=local.snapshot_lease_admin,schema_reader_lease=local.snapshot_lease_schema_reader,schema_admin_lease=local.snapshot_lease_schema_admin}'
            for variables in [{}, {'vpa_enabled': False}, {'pgbouncer_read_only_enabled': True}, {'pgbouncer_read_write_enabled': False}, {'pgbouncer_read_only_enabled': False, 'pgbouncer_read_write_enabled': False}]:
                assert evaluate(current, expression, variables) == evaluate(baseline, expression, variables), variables
            print('Default normalized Pooler/VPA/PDB manifests, exact schema-init command and four credential creation statement arrays equal baseline in all five endpoint/VPA configurations.')
        print('TOML, TLS mounts, SQL readiness, credential isolation and auth-query privilege checks passed.')


if __name__ == '__main__':
    main()
