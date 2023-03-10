#!/usr/bin/env python
"""
Uses Superset's REST API to create the OARS datastores, charts, and dashboard.
"""
import os
import zipfile
import tempfile
from supersetapiclient.client import SupersetClient

SUPERSET_URL_SCHEME = "{% if ENABLE_HTTPS %}https{% else %}http{% endif %}"
SUPERSET_HOST_URL = f"{SUPERSET_URL_SCHEME}://superset:{{ SUPERSET_PORT }}"
SUPERSET_ADMIN_USERNAME = "{{ SUPERSET_ADMIN_USERNAME }}"
SUPERSET_ADMIN_PASSWORD = "{{ SUPERSET_ADMIN_PASSWORD }}"
SUPERSET_DATA_ASSETS_DIR = "/app/oars/data/assets/"
SUPERSET_DB_PASSWORDS = {
    # Database names neet to match file names under SUPERSET_DATA_ASSETS_DIR/databases/
    "OpenedX_MySQL": "{{ OPENEDX_MYSQL_PASSWORD }}",
    "OpenedX_Clickhouse": "{{ OARS_CLICKHOUSE_REPORT_PASSWORD }}",
}
OPENEDX_DASHBOARD_SLUG = "{{ SUPERSET_XAPI_DASHBOARD_SLUG }}"

def update_assets():
    # Need to override this setting to allow OAuth over http
    if SUPERSET_URL_SCHEME == 'http':
        os.environ['OAUTHLIB_INSECURE_TRANSPORT'] = '1'
        verify=False
    else:
        verify=True

    superset = SupersetClient(
        host=SUPERSET_HOST_URL,
        username=SUPERSET_ADMIN_USERNAME,
        password=SUPERSET_ADMIN_PASSWORD,
        verify=verify,
    )

    # Import the zipped asset files
    zip_file = zip_dir(SUPERSET_DATA_ASSETS_DIR)
    superset.dashboards.import_file(
        zip_file.name,
        overwrite=True,
        passwords=SUPERSET_DB_PASSWORDS,
    )
    # Remove the temporary zipfile
    os.unlink(zip_file.name)

    # Mark the imported dashboard as Published
    dashboard = superset.dashboards.find(slug=OPENEDX_DASHBOARD_SLUG)[0]
    dashboard.published = True
    # TODO: Enable feature flag DASHBOARD_RBAC, and set dashboard.roles = ["Open edX"]
    # Consider finishing https://github.com/opus-42/superset-api-client/pull/31
    dashboard.save()


def zip_dir(zip_dir):
    """
    Zips up the contents of the given dir to a temporary file,
    and returns the temporary file pointer.
    """
    fp = tempfile.NamedTemporaryFile(delete=False, suffix=".zip")
    asset_dir = os.path.abspath(zip_dir)
    archive_base_dir = 'assets'
    with zipfile.ZipFile(fp, "w") as ziph:  # ziph is zipfile handle
        for root, dirs, files in os.walk(asset_dir):
            if root == asset_dir:
                archive_dir = archive_base_dir
            else:
                archive_dir = os.path.join(archive_base_dir, os.path.relpath(root, asset_dir))
                # Add this subdir to the zip file
                ziph.write(root, arcname=archive_dir)

            # Add all the files in root to the zip file
            for file in files:
                ziph.write(
                    os.path.join(root, file),
                    arcname=os.path.join(archive_dir, file),
                )
    fp.close()
    return fp


if __name__ == "__main__":
    update_assets()
