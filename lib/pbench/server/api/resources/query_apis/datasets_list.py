from dateutil import parser
from flask import jsonify
from logging import Logger
from typing import Any, AnyStr, Dict

from pbench.server import PbenchServerConfig
from pbench.server.api.resources.query_apis import (
    ElasticBase,
    Schema,
    Parameter,
    ParamType,
)


class DatasetsList(ElasticBase):
    """
    Get a list of dataset run documents for a controller.
    """

    def __init__(self, config: PbenchServerConfig, logger: Logger):
        super().__init__(
            config,
            logger,
            Schema(
                Parameter("user", ParamType.USER, required=True),
                Parameter("controller", ParamType.STRING, required=True),
                Parameter("start", ParamType.DATE, required=True),
                Parameter("end", ParamType.DATE, required=True),
            ),
        )

    def assemble(self, json_data: Dict[AnyStr, Any]) -> Dict[AnyStr, Any]:
        """
        Get a list of datasets recorded for a particular controller and either
        owned by a specified username, or publicly accessible, within the set
        of Elasticsearch run indices defined by the date range.

        {
            "user": "username",
            "controller": "controller-name",
            "start": "start-time",
            "end": "end-time"
        }

        JSON parameters:
            user: specifies the owner of the data to be searched; it need not
                necessarily be the user represented by the session token
                header, assuming the session user is authorized to view "user"s
                data. If "user": None is specified, then only public datasets
                will be returned.

            "controller" is the name of a Pbench agent controller (normally a
                host name).

            "start" and "end" are time strings representing a set of
                Elasticsearch run document indices in which the dataset will be
                found.
            """
        user = json_data["user"]
        controller = json_data["controller"]
        start = json_data["start"]
        end = json_data["end"]

        self.logger.info(
            "Discover datasets for user {}, prefix {}: ({}: {} - {})",
            user,
            self.prefix,
            controller,
            start,
            end,
        )

        # TODO: Need to refactor the template processing code from indexer.py
        # to maintain the essential indexing information in a persistent DB
        # (probably a Postgresql table) so that it can be shared here and by
        # the indexer without re-loading on each access. For now, the index
        # version is hardcoded.
        uri_fragment = self._gen_month_range(".v6.run-data.", start, end)
        return {
            "path": f"/{uri_fragment}/_search",
            "kwargs": {
                "json": {
                    "_source": {
                        "includes": [
                            "@metadata.controller_dir",
                            "@metadata.satellite",
                            "run.controller",
                            "run.start",
                            "run.end",
                            "run.name",
                            "run.config",
                            "run.prefix",
                            "run.id",
                        ]
                    },
                    "sort": {"run.end": {"order": "desc"}},
                    "query": {
                        "bool": {
                            "filter": [
                                {"term": self._get_user_term(user)},
                                {"term": {"run.controller": controller}},
                            ]
                        }
                    },
                    "size": 5000,
                }
            },
        }

    def postprocess(self, es_json: Dict[AnyStr, Any]) -> Dict[AnyStr, Any]:
        """
        Returns a list of run documents including the name, the associated
        controller, start and end timestamps:
        [
            {
                "key": "fio_rhel8_kvm_perf43_preallocfull_nvme_run4_iothread_isolcpus_2020.04.29T12.49.13",
                "startUnixTimestamp": 1588178953561,
                "run.name": "fio_rhel8_kvm_perf43_preallocfull_nvme_run4_iothread_isolcpus_2020.04.29T12.49.13",
                "run.controller": "dhcp31-187.example.com,
                "run.start": "2020-04-29T12:49:13.560620",
                "run.end": "2020-04-29T13:30:04.918704"
            }
        ]
        """
        datasets = []
        hits = es_json["hits"]["hits"]
        self.logger.info("{} controllers found", len(hits))
        for dataset in hits:
            src = dataset["_source"]
            run = src["run"]
            d = {
                "key": run["name"],
                "run.name": run["name"],
                "run.controller": run["controller"],
                "run.start": run["start"],
                "run.end": run["end"],
                "id": run["id"],
            }
            try:
                timestamp = parser.parse(run["start"]).utcfromtimestamp()
            except Exception as e:
                self.logger.info(
                    "Can't parse start time {} to integer timestamp: {}",
                    run["start"],
                    e,
                )
                timestamp = dataset["sort"][0]

            d["startUnixTimestamp"] = timestamp
            if "config" in run:
                d["run.config"] = run["config"]
            if "prefix" in run:
                d["run.prefix"] = run["prefix"]
            if "@metadata" in src:
                meta = src["@metadata"]
                if "controller_dir" in meta:
                    d["@metadata.controller_dir"] = meta["controller_dir"]
                if "satellite" in meta:
                    d["@metadata.satellite"] = meta["satellite"]
            datasets.append(d)
        # construct response object
        return jsonify(datasets)
