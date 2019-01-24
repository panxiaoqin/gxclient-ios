//
//  GXClient.m
//  gxclient-ios
//
//  Created by David Lan on 2019/1/21.
//  Copyright © 2019年 GXChain. All rights reserved.
//

#import "GXClient.h"
#import "GXRPC.h"
#import "GXUtil.h"
#import "GXPrivateKey.h"
#import "GXPublicKey.h"
#import <AFNetworking.h>
#import "NSDictionary+Expand.h"
#import "GXTransactionBuilder.h"
#import "GXTransferOperation.h"
#import "GXMemoData.h"

const NSString* DEFAULT_FAUCET=@"https://opengateway.gxb.io";

@interface GXClient()
@property(nonatomic,strong) GXRPC* rpc;
@property(nonatomic,strong) NSString* private_key;
@property(nonatomic,strong) NSString* account;
@property(nonatomic,strong) id<GXClientSignatureProvider> signatureProvider;
@property(nonatomic,strong) NSString* chain_id;
@end

@implementation GXClient

#pragma mark - Constructors

+(instancetype)clientWithEntryPoint:(NSString *)entryPoint{
    GXClient * client = [[GXClient alloc] init];
    client.rpc = [GXRPC rpcWithEntryPoint:entryPoint];
    return client;
}

+(instancetype)clientWithEntryPoint:(NSString *)entryPoint keyProvider:(NSString *)privateKey account:(NSString *)accountName{
    GXClient * client = [self clientWithEntryPoint:entryPoint];
    client.private_key= privateKey;
    client.account = accountName;
    return client;
}

+(instancetype)clientWithEntryPoint:(NSString *)entryPoint signatureProvider:(id<GXClientSignatureProvider>)provider account:(NSString *)accountName{
    GXClient * client = [self clientWithEntryPoint:entryPoint];
    client.signatureProvider = provider;
    client.account = accountName;
    return client;
}

#pragma mark - KeyPair API

-(NSDictionary *)generateKey:(NSString*)brain_key{
    NSString* brainKey = brain_key==nil||[brain_key isEqualToString:@""]? [GXUtil suggest_brain_key]:[GXUtil normalize_brain_key:brain_key];
    NSString* privateKey = [GXUtil get_brain_private_key:brainKey sequence:0];
    NSString* publicKey = [GXUtil private_to_public:privateKey];
    return @{
             @"brainKey":brainKey,
             @"privateKey":privateKey,
             @"publicKey":publicKey
             };
}

-(NSString*) privateToPublic:(NSString*)privateKey{
    return [GXUtil private_to_public:privateKey];
}

-(BOOL) isValidPrivate:(NSString*)privateKey{
    @try{
        return [GXPrivateKey fromWif:privateKey] != nil;
    }@catch(NSException* ex){
        return NO;
    }
}

-(BOOL) isValidPublic:(NSString*)publicKey{
    @try{
        return [GXPublicKey fromString:publicKey] != nil;
    }@catch(NSException* ex){
        return NO;
    }
}

#pragma mark - Chain API

-(void) query:(NSString*)method params:(NSArray*)params callback:(void(^)(NSError * error, id responseObject)) callback{
    [self.rpc query:method params:params callback:callback];
}

-(void) getChainID:(void (^)(NSError *, id))callback{
    if(self.chain_id){
        callback(nil,self.chain_id);
    } else{
        [self query:@"get_chain_id" params:@[] callback:^(NSError *error, id responseObject) {
            if(error == nil){
                self.chain_id = responseObject;
            }
            callback(error,responseObject);
        }];
    }
}
-(void)getDynamicGlobalProperties:(void(^)(NSError * error, id responseObject)) callback{
    [self query:@"get_dynamic_global_properties" params:@[] callback:callback];
}

-(void) getBlock:(NSInteger)height callback:(void (^)(NSError *, id))callback{
    [self query:@"get_block" params:@[@(height)] callback:callback];
}

-(void)transfer:(NSString *)to memo:(NSString *)memo amount:(NSString *)amountAsset feeAsset:(NSString *)feeAsset broadcast:(BOOL)broadcast callback:(void (^)(NSError *, id))callback{
    [self getChainID:^(NSError *error, id responseObject) {
        if(error){
            callback(error,responseObject);
        } else{
            // get from account
            [self getAccount:self.account callback:^(NSError *error, id responseObject) {
                if(error){
                    callback(error,responseObject);
                } else if([responseObject objectForKey:@"id"]!=nil){
                    NSDictionary* fromAccount = responseObject;
                    // get to account
                    [self getAccount:to callback:^(NSError *error, id responseObject) {
                        if(error){
                            callback(error,responseObject);
                        } else if([responseObject objectForKey:@"id"]!=nil){
                            NSDictionary* toAccount = responseObject;
                            float amount = [[[amountAsset componentsSeparatedByString:@" "] objectAtIndex:0] floatValue];
                            NSString* asset = [[amountAsset componentsSeparatedByString:@" "] objectAtIndex:1];
                            if(asset){
                                // get asset info
                                [self getAsset:asset callback:^(NSError *error, id responseObject) {
                                    if(error){
                                        callback(error,responseObject);
                                    } else if([responseObject objectForKey:@"id"]!=nil){
                                        NSDictionary* asset = responseObject;
                                        
                                        GXTransferOperation * op = [[GXTransferOperation alloc] init];
                                        op.from=[fromAccount objectForKey:@"id"];
                                        op.to=[toAccount objectForKey:@"id"];
                                        uint64_t am = (int64_t)(amount*powf(10.0, [[asset objectForKey:@"precision"] floatValue]));
                                        op.amount=[[GXAssetAmount alloc] initWithAsset:[asset objectForKey:@"id"] amount:am];
                                        NSString* toMemoKey = [[toAccount objectForKey:@"options"] objectForKey:@"memo_key"];
                                        op.memo=[GXMemoData memoWithPrivate:self.private_key public:toMemoKey message:memo];
                                        op.extensions=@[];
                                        
                                        if(feeAsset!=nil && [feeAsset isEqualToString:[asset objectForKey:@"symbol"]]){
                                            op.fee=[[GXAssetAmount alloc] initWithAsset:[asset objectForKey:@"id"] amount:0];
                                            GXTransactionBuilder * tx =[[GXTransactionBuilder alloc] initWithOperations:@[op] rpc:self.rpc chainID:self.chain_id];
                                            [tx add_signer:[GXPrivateKey fromWif:self.private_key]];
                                            
                                            [tx processTransaction:^(NSError *err, NSDictionary *tx) {
                                                callback(err,tx);
                                            } broadcast:broadcast];
                                        } else{
                                            [self getAsset:feeAsset callback:^(NSError *error, id responseObject) {
                                                if(error){
                                                    callback(error,nil);
                                                } else{
                                                    op.fee=[[GXAssetAmount alloc] initWithAsset:[responseObject objectForKey:@"id"] amount:0];
                                                    GXTransactionBuilder * tx =[[GXTransactionBuilder alloc] initWithOperations:@[op] rpc:self.rpc chainID:self.chain_id];
                                                    [tx add_signer:[GXPrivateKey fromWif:self.private_key]];
                                                    [tx processTransaction:^(NSError *err, NSDictionary *tx) {
                                                        callback(err,tx);
                                                    } broadcast:broadcast];
                                                }
                                            }];
                                        }
                                        
                                    } else{
                                        NSError* err = [NSError errorWithDomain:@"asset_not_exist" code:-1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"%@ not exist", asset]}];
                                        callback(err,nil);
                                    }
                                }];
                            }
                        } else{
                            NSError* err = [NSError errorWithDomain:@"account_not_found" code:-1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"%@ not exist", to]}];
                            callback(err,nil);
                        }
                    }];
                } else{
                    NSError* err = [NSError errorWithDomain:@"account_not_found" code:-1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"%@ not exist", self.account]}];
                    callback(err,nil);
                }
            }];
        }
    }];
}

-(void)vote:(NSArray *)accounts feeAsset:(NSString *)feeAsset broadcast:(BOOL)broadcast callback:(void (^)(NSError *, id))callback{
    // TODO
}

-(void)broadcast:(NSDictionary *)tx callback:(void (^)(NSError *, id))callback{
    [self.rpc broadcast:tx callback:callback];
}

#pragma mark - Faucet API

-(void)registerAccount:(NSString *)accountName activeKey:(NSString *)activeKey ownerKey:(NSString *)ownerKey memoKey:(NSString *)memoKey faucet:(NSString*)faucetUrl callback:(void (^)(NSError * error, id responseObject))callback{
    AFHTTPSessionManager* manager = [AFHTTPSessionManager manager];
    manager.requestSerializer = [AFJSONRequestSerializer serializer];
    manager.responseSerializer = [AFJSONResponseSerializer serializer];
    manager.responseSerializer.acceptableContentTypes = [NSSet setWithObjects:@"text/html",@"application/json", @"text/json", nil];
    manager.requestSerializer.timeoutInterval=10.0;
    manager.securityPolicy.allowInvalidCertificates=NO;
    manager.securityPolicy.validatesDomainName=YES;
    NSAssert([self isValidPublic:activeKey], @"invalid active key");
    if(ownerKey!=nil){
        NSAssert([self isValidPublic:ownerKey], @"invalid owner key");
    }
    if(memoKey!=nil){
        NSAssert([self isValidPublic:memoKey], @"invalid memo key");
    }
    NSDictionary* params = @{
                             @"account":@{
                                  @"name":accountName,
                                  @"active_key":activeKey,
                                  @"owner_key":ownerKey?ownerKey:activeKey,
                                  @"memo_key":memoKey?memoKey:activeKey
                              }
    };
    [manager POST:[NSString stringWithFormat:@"%@%@",faucetUrl,@"/account/register"] parameters:params progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        callback(nil,responseObject);
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSString* responseText = [[NSString alloc] initWithData:(NSData *)error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey] encoding:NSUTF8StringEncoding];
        callback(error,[NSDictionary fromJSON:responseText]);
    }];
}

-(void)registerAccount:(NSString *)accountName activeKey:(NSString *)activeKey ownerKey:(NSString *)ownerKey memoKey:(NSString *)memoKey callback:(void (^)(NSError * error, id responseObject))callback{
    [self registerAccount:accountName activeKey:activeKey ownerKey:ownerKey memoKey:memoKey faucet:[DEFAULT_FAUCET copy] callback:callback];
}

#pragma mark - Account API
-(void)getAccount:(NSString*)accountName callback:(void(^)(NSError * error, id responseObject)) callback{
    [self query:@"get_account_by_name" params:@[accountName] callback:callback];
}
-(void)getAccountBalances:(NSString*)accountName callback:(void(^)(NSError * error, id responseObject)) callback{
    [self getAccount:accountName callback:^(NSError *error, id responseObject) {
        if(error){
            callback(error,responseObject);
        } else{
            [self query:@"get_account_balances" params:@[[responseObject objectForKey:@"id"]] callback:callback];
        }
    }];
}
-(void)getAccountByPublicKey:(NSString*)publicKey callback:(void(^)(NSError * error, id responseObject)) callback{
    [self query:@"get_key_references" params:@[@[publicKey]] callback:callback];
}

#pragma mark - Asset API
-(void)getAsset:(NSString*)symbol callback:(void(^)(NSError * error, id responseObject)) callback{
    [self query:@"lookup_asset_symbols" params:@[@[symbol]] callback:^(NSError *error, id responseObject) {
        if(error){
            callback(error,responseObject);
        } else{
            callback(nil,[responseObject objectAtIndex:0]);
        }
    }];
}

#pragma mark - Object API

-(void)getObject:(NSString*)objectID callback:(void(^)(NSError * error, id responseObject)) callback{
    [self getObjects:@[objectID] callback:^(NSError *error, id responseObject) {
        if(error){
            callback(error,responseObject);
        } else{
            callback(nil,[responseObject objectAtIndex:0]);
        }
    }];
}

-(void)getObjects:(NSArray*)objectIDs callback:(void(^)(NSError * error, id responseObject)) callback{
    [self query:@"get_objects" params:@[objectIDs] callback:callback];
}

#pragma mark - Contract API

-(void) callContract:(NSString*)contractName method:(NSString*)method params:(NSDictionary*)params amount:(NSString*)amountAsset broadcast:(BOOL)broadcast callback:(void(^)(NSError * error, id responseObject)) callback{
    // TODO
}

-(void) getContractABI:(NSString*)contract callback:(void(^)(NSError * error, id responseObject)) callback{
    [self getAccount:contract callback:^(NSError *error, id responseObject) {
        if(error){
            callback(error,responseObject);
        } else{
            callback(nil, [responseObject objectForKey:@"abi"]);
        }
    }];
}

-(void) getContractTables:(NSString*)contract callback:(void(^)(NSError * error, id responseObject)) callback{
    [self getAccount:contract callback:^(NSError *error, id responseObject) {
        if(error){
            callback(error,responseObject);
        } else{
            callback(nil, [[responseObject objectForKey:@"abi"] objectForKey:@"tables"]);
        }
    }];
}

-(void) getTableObjects:(NSString*)contract table:(NSString*)tableName start:(uint64_t)start limit:(NSInteger)limit reverse:(BOOL)reverse callback:(void(^)(NSError * error, id responseObject)) callback{
    [self query:@"get_table_objects_ex" params:@[contract,tableName,@{@"lower_bound":@(start),@"upper_bound":@(-1),@"limit":@(limit),@"reverse":@(reverse)}] callback:callback];
}

#pragma mark - Private methods

@end
