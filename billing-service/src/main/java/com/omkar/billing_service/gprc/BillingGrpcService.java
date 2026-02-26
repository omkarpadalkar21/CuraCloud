package com.omkar.billing_service.gprc;

import billing.BillingRequest;
import billing.BillingResponse;
import io.grpc.stub.StreamObserver;
import net.devh.boot.grpc.server.service.GrpcService;
import billing.BillingServiceGrpc.BillingServiceImplBase;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

@GrpcService
public class BillingGrpcService extends BillingServiceImplBase {
    private static final Logger log = LoggerFactory.getLogger(BillingGrpcService.class);

    @Override
    public void createBillingAccount(BillingRequest request, StreamObserver<BillingResponse> responseObserver) {
        log.info("Request received to create billing account: {}", request.toString());

        // business logic

        BillingResponse response = BillingResponse.newBuilder()
                .setAccountId("ACC12345")
                .setStatus("Active")
                .build();

        responseObserver.onNext(response); // allows sending multiple responses to the client before terminating the connection
        responseObserver.onCompleted();
    }
}
