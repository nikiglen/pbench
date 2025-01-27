import logging
import os

import pytest
import responses

from pbench.agent import PbenchAgentConfig
from pbench.agent.results import CopyResultTb
from pbench.common.logger import get_pbench_logger
from pbench.test.unit.agent.task.common import tarball, bad_tarball


class TestCopyResults:
    @pytest.fixture(autouse=True)
    def config_and_logger(self, valid_config):
        # Setup the configuration and logger
        self.config = PbenchAgentConfig(os.environ["_PBENCH_AGENT_CONFIG"])
        self.logger = get_pbench_logger("pbench", self.config)
        yield
        # Teardown the setup
        self.config, self.logger = None, None

    @responses.activate
    def test_copy_tar(self, valid_config):
        responses.add(
            responses.PUT,
            "http://pbench.example.com/api/v1/upload/ctrl/controller",
            status=200,
        )
        crt = CopyResultTb("controller", tarball, self.config, self.logger)
        crt.copy_result_tb("token")

    @responses.activate
    def test_bad_tar(self, caplog, valid_config):
        responses.add(
            responses.PUT,
            "http://pbench.example.com/api/v1/upload/ctrl/controller",
            status=200,
        )
        expected_error_message = (
            f"FileNotFoundError: Tarball '{bad_tarball}' does not exist"
        )
        caplog.set_level(logging.ERROR, logger=self.logger.name)
        with pytest.raises(FileNotFoundError) as e:
            crt = CopyResultTb("controller", bad_tarball, self.config, self.logger)
            crt.copy_result_tb("token")
        assert str(e).endswith(expected_error_message)
