declare module "virtual:sample-images" {
  export type SampleImage = {
    readonly path: string;
    readonly label: string;
    readonly width: number;
    readonly height: number;
  };

  export const sampleImages: readonly SampleImage[];
}
