import unittest

from app.app import app


class AppTestCase(unittest.TestCase):
    def setUp(self):
        self.client = app.test_client()

    def test_healthz(self):
        response = self.client.get('/healthz')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()['status'], 'ok')

    def test_readyz(self):
        response = self.client.get('/readyz')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()['status'], 'ready')

    def test_metrics_endpoint(self):
        response = self.client.get('/metrics')
        self.assertEqual(response.status_code, 200)
        self.assertIn(b'demo_http_requests_total', response.data)

    def test_fault_endpoints_disabled_by_default(self):
        for path in ('/simulate/error', '/simulate/slow', '/simulate/memory', '/simulate/degraded'):
            response = self.client.get(path)
            self.assertEqual(response.status_code, 404, path)
            self.assertEqual(response.get_json()['error'], 'fault endpoints disabled')


if __name__ == '__main__':
    unittest.main()
