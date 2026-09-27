"""Offline OCI CLI 3.94.0 renderer fixture; never opens a cloud connection.

The subprocess imports the installed CLI's render_response, then supplies a
controlled SDK-shaped response. Only fixed public fixture data is accepted.
"""

import sys
import time
from types import SimpleNamespace

from oci_cli.cli_util import render_response


class Context:
    obj = {"debug": False, "query": None, "output": "json", "raw_output": False}
    command = SimpleNamespace(params=[])


def response(data, headers=None):
    render_response(SimpleNamespace(data=data, headers=headers or {}), Context())


def main():
    if len(sys.argv) != 2:
        return 2
    case = sys.argv[1]
    if case == "empty":
        response([], {"opc-request-id": "fixture", "content-type": "application/json"})
    elif case == "empty-total-zero":
        response([], {"opc-total-items": "0"})
    elif case == "empty-etag":
        response([], {"etag": "fixture-etag"})
    elif case == "one":
        response([{"id": "fixture-1"}])
    elif case == "two":
        response([{"id": "fixture-1"}, {"id": "fixture-2"}])
    elif case == "region-subscription":
        response([{"is-home-region": True, "region-name": "ap-seoul-1", "status": "READY"}])
    elif case == "compartment":
        response([{"id": "ocid1.compartment.oc1..offline", "lifecycle-state": "ACTIVE"}])
    elif case == "availability-domain":
        response([{"name": "AD-1"}])
    elif case == "empty-next-page":
        response([], {"opc-next-page": "fixture-next"})
    elif case == "empty-stderr":
        response([])
        print("WARNING: fixture warning", file=sys.stderr)
    elif case == "explicit-empty":
        print('{"data": []}')
    elif case == "total-nonzero":
        print('{"opc-total-items": 1}')
    elif case == "invalid-json":
        print("not-json")
    elif case == "null-data":
        print('{"data": null}')
    elif case == "nonarray-data":
        print('{"data": {"id":"fixture"}}')
    elif case == "empty-array-json":
        print("[]")
    elif case == "empty-object-json":
        print("{}")
    elif case == "empty-list-total-one":
        print('{"data":[],"opc-total-items":"1"}')
    elif case == "no-data-unknown-header":
        print('{"unexpected":"fixture"}')
    elif case == "get-no-data":
        print("{}")
    elif case == "exit401":
        print('{"code":"NotAuthenticated","status":401,"message":"SECRET_FIXTURE"}', file=sys.stderr)
        return 7
    elif case == "exit403":
        print('{"code":"NotAuthorized","status":403,"message":"SECRET_FIXTURE"}', file=sys.stderr)
        return 7
    elif case == "exit404":
        print('{"code":"NotAuthorizedOrNotFound","status":404,"message":"SECRET_FIXTURE"}', file=sys.stderr)
        return 7
    elif case == "exit-other":
        print("SECRET_FIXTURE", file=sys.stderr)
        return 9
    elif case == "timeout":
        time.sleep(4)
    else:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
