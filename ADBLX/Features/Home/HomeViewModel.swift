// ADBLX/Features/Home/HomeViewModel.swift
import Observation

@Observable
final class HomeViewModel {
    private let service: HomeService

    var status: HomeStatus?
    var isLoading = false

    init(service: HomeService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        status = await service.fetchStatus()
        isLoading = false
    }
}
